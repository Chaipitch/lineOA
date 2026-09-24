@IsTest
private class LineAdminControllerTest {
  private static final String SITE = 'https://acme.my.salesforce-sites.com/linewebhook';

  @TestSetup
  static void setup() {
    LineTestFactory.ensurePackageAccess();
    LineTestFactory.createUser(new List<String>{ 'LINE_Admin' });
    LineTestFactory.createUser(new List<String>{ 'LINE_Chat_User' });
    // Registration makes callouts, so the Site URL must already be committed: Apex refuses a callout
    // after DML in the same transaction. In the UI these are two separate Apex calls.
    insert as system new LINE_Settings__c(
      SetupOwnerId = UserInfo.getOrganizationId(),
      Site_Base_Url__c = SITE
    );
  }

  private static User admin() {
    return userWith('LINE_Admin');
  }

  private static User rep() {
    return userWith('LINE_Chat_User');
  }

  private static User userWith(String permissionSetName) {
    return [
      SELECT Id
      FROM User
      WHERE
        Username LIKE 'line.test.%'
        AND Id IN (
          SELECT AssigneeId
          FROM PermissionSetAssignment
          WHERE PermissionSet.Name = :permissionSetName
        )
      LIMIT 1
    ];
  }

  // ---------- permission ----------

  @IsTest
  static void repCannotUseAnyAdminMethod() {
    LineTestFactory.ensurePackageAccess();
    Test.setMock(HttpCalloutMock.class, new LineHttpMock());

    Test.startTest();
    System.runAs(rep()) {
      for (Integer i = 0; i < 4; i++) {
        try {
          switch on i {
            when 0 {
              LineAdminController.getSettings();
            }
            when 1 {
              LineAdminController.getOAs();
            }
            when 2 {
              LineAdminController.saveSettings(
                SITE,
                null,
                null,
                null,
                null,
                null,
                true,
                true,
                false
              );
            }
            when else {
              LineAdminController.registerOA(
                LineTestFactory.CHANNEL_A,
                LineTestFactory.SECRET_A,
                UserInfo.getUserId()
              );
            }
          }
          Assert.fail('Expected AuraHandledException for method ' + i);
        } catch (AuraHandledException e) {
          Assert.areEqual(System.Label.LINE_Error_Admin_Only, e.getMessage());
        }
      }
    }
    Test.stopTest();

    Assert.areEqual(
      0,
      [SELECT COUNT() FROM LINE_OA_Configuration__c WITH SYSTEM_MODE],
      'A rep cannot register an OA'
    );
  }

  // ---------- settings ----------

  @IsTest
  static void settingsRoundTripAndWebhookUrl() {
    LineTestFactory.ensurePackageAccess();
    delete as system [SELECT Id FROM LINE_Settings__c WITH SYSTEM_MODE];
    LineSettings.reset();
    LineAdminController.SettingsView saved;

    Test.startTest();
    System.runAs(admin()) {
      LineAdminController.SettingsView before = LineAdminController.getSettings();
      Assert.isNull(before.siteBaseUrl, 'Nothing configured yet');
      Assert.isNull(before.webhookUrl);
      Assert.areEqual(5, before.pollIntervalSeconds, 'Code default');

      saved = LineAdminController.saveSettings(
        SITE + '/',
        UserInfo.getUserId(),
        8,
        3,
        2,
        6,
        false,
        false,
        true
      );
    }
    Test.stopTest();

    Assert.areEqual(SITE, saved.siteBaseUrl, 'Trailing slash removed');
    Assert.areEqual(
      SITE + LineNamespace.webhookPath(),
      saved.webhookUrl,
      'Webhook URL includes the namespace path'
    );
    Assert.areEqual(admin().Id, saved.fallbackOwnerId, 'The running admin');
    Assert.areEqual(8, saved.pollIntervalSeconds);
    Assert.areEqual(3, saved.inviteCodeExpiryDays);
    Assert.areEqual(2, saved.publicLinkExpiryDays);
    Assert.areEqual(6, saved.messageRetentionMonths);
    Assert.isFalse(saved.dailySyncEnabled);
    Assert.isFalse(saved.autoCreateContact, 'The admin turned it off');
    Assert.isTrue(saved.updateContactOwnerOnReassign);
  }

  @IsTest
  static void blankNumbersFallBackToDefaults() {
    LineTestFactory.ensurePackageAccess();
    LineAdminController.SettingsView saved;

    System.runAs(admin()) {
      saved = LineAdminController.saveSettings(
        SITE,
        null,
        null,
        null,
        null,
        null,
        true,
        true,
        false
      );
    }

    Assert.areEqual(5, saved.pollIntervalSeconds);
    Assert.isTrue(saved.autoCreateContact, 'On by default');
    Assert.areEqual(7, saved.inviteCodeExpiryDays);
    Assert.areEqual(7, saved.publicLinkExpiryDays);
    Assert.areEqual(0, saved.messageRetentionMonths);
    Assert.isNull(saved.fallbackOwnerId);
  }

  // ---------- registration ----------

  @IsTest
  static void registerCreatesOaAndStoresSecret() {
    LineTestFactory.ensurePackageAccess();
    LineHttpMock mock = new LineHttpMock();
    Test.setMock(HttpCalloutMock.class, mock);
    User admin = admin();

    Test.startTest();
    LineAdminController.OaView view;
    System.runAs(admin) {
      view = LineAdminController.registerOA(
        LineTestFactory.CHANNEL_A,
        LineTestFactory.SECRET_A,
        admin.Id
      );
    }
    Test.stopTest();

    Assert.areEqual('OA A', view.name);
    Assert.areEqual(LineTestFactory.CHANNEL_A, view.channelId);
    Assert.areEqual('Ubot_a', view.botUserId);
    Assert.areEqual('@111aaaaa', view.basicId);
    Assert.areEqual(admin.Id, view.assignedRepId);
    Assert.isTrue(view.isActive);

    Assert.isFalse(
      JSON.serialize(view).contains(LineTestFactory.SECRET_A),
      'The view never carries the secret'
    );
    Assert.areEqual(
      LineTestFactory.SECRET_A,
      LineCredentialStore.getSecret(LineTestFactory.CHANNEL_A),
      'The secret is stored in the protected setting'
    );
    Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(
      mock.requestsTo('/webhook/endpoint')[0].getBody()
    );
    Assert.areEqual(
      SITE + LineNamespace.webhookPath(),
      body.get('endpoint'),
      'LINE is pointed at this org'
    );
  }

  @IsTest
  static void registeredOasAreListed() {
    LineTestFactory.ensurePackageAccess();
    Test.setMock(HttpCalloutMock.class, new LineHttpMock());
    User admin = admin();

    Test.startTest();
    List<LineAdminController.OaView> oas;
    System.runAs(admin) {
      LineAdminController.registerOA(
        LineTestFactory.CHANNEL_A,
        LineTestFactory.SECRET_A,
        admin.Id
      );
      oas = LineAdminController.getOAs();
    }
    Test.stopTest();

    Assert.areEqual(1, oas.size());
    Assert.areEqual(LineTestFactory.CHANNEL_A, oas[0].channelId);
    Assert.isNotNull(oas[0].webhookStatus);
  }

  @IsTest
  static void badCredentialsAreReportedAndNothingIsSaved() {
    LineTestFactory.ensurePackageAccess();
    LineHttpMock mock = new LineHttpMock();
    mock.stub(
      'POST',
      '/oauth2/v3/token',
      400,
      '{"error":"invalid_client","error_description":"invalid client"}'
    );
    Test.setMock(HttpCalloutMock.class, mock);
    User admin = admin();

    Test.startTest();
    System.runAs(admin) {
      try {
        LineAdminController.registerOA(
          LineTestFactory.CHANNEL_A,
          'wrong_fake_secret',
          admin.Id
        );
        Assert.fail('Expected AuraHandledException');
      } catch (AuraHandledException e) {
        Assert.areEqual(
          System.Label.LINE_Error_Credentials_Invalid,
          e.getMessage()
        );
        Assert.isFalse(e.getMessage().contains('wrong_fake_secret'));
      }
    }
    Test.stopTest();

    Assert.areEqual(
      0,
      [SELECT COUNT() FROM LINE_OA_Configuration__c WITH SYSTEM_MODE]
    );
    Assert.isNull(LineCredentialStore.getSecret(LineTestFactory.CHANNEL_A));
  }

  @IsTest
  static void registeringWithoutSiteUrlExplainsWhy() {
    LineTestFactory.ensurePackageAccess();
    // No Site URL configured: the guard must fire before any callout.
    delete as system [SELECT Id FROM LINE_Settings__c WITH SYSTEM_MODE];
    LineSettings.reset();
    LineHttpMock mock = new LineHttpMock();
    Test.setMock(HttpCalloutMock.class, mock);
    User admin = admin();

    System.runAs(admin) {
      try {
        LineAdminController.registerOA(
          LineTestFactory.CHANNEL_A,
          LineTestFactory.SECRET_A,
          admin.Id
        );
        Assert.fail('Expected AuraHandledException');
      } catch (AuraHandledException e) {
        Assert.areEqual(
          System.Label.LINE_Error_Site_Url_Missing,
          e.getMessage()
        );
      }
    }
    Assert.areEqual(0, mock.requests.size(), 'No callout without a Site URL');
  }
}
