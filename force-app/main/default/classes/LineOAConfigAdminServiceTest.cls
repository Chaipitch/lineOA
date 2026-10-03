@IsTest
private class LineOAConfigAdminServiceTest {
  private static final String SITE = 'https://acme.my.salesforce-sites.com/linewebhook';

  @TestSetup
  static void setup() {
    LineTestFactory.ensurePackageAccess();
    insert as system new LINE_Settings__c(
      SetupOwnerId = UserInfo.getOrganizationId(),
      Site_Base_Url__c = SITE
    );
  }

  @IsTest
  static void registerFillsBotFieldsSetsWebhookAndStoresSecret() {
    LineTestFactory.ensurePackageAccess();
    LineHttpMock mock = new LineHttpMock();
    Test.setMock(HttpCalloutMock.class, mock);

    Test.startTest();
    LineOAConfigAdminService.RegistrationResult result = LineOAConfigAdminService.registerOA(
      ' ' + LineTestFactory.CHANNEL_A + ' ',
      LineTestFactory.SECRET_A,
      UserInfo.getUserId()
    );
    Test.stopTest();

    LINE_OA_Configuration__c oa = [
      SELECT
        Name,
        Channel_Id__c,
        Bot_User_Id__c,
        Basic_Id__c,
        Picture_Url__c,
        Assigned_Rep__c,
        Is_Active__c,
        Webhook_Status__c
      FROM LINE_OA_Configuration__c
      WITH SYSTEM_MODE
    ];
    Assert.areEqual('OA A', oa.Name);
    Assert.areEqual(
      LineTestFactory.CHANNEL_A,
      oa.Channel_Id__c,
      'Channel ID is trimmed'
    );
    Assert.areEqual('Ubot_a', oa.Bot_User_Id__c);
    Assert.areEqual('@111aaaaa', oa.Basic_Id__c);
    Assert.areEqual('https://example.com/oa.png', oa.Picture_Url__c);
    Assert.areEqual(UserInfo.getUserId(), oa.Assigned_Rep__c);
    Assert.isTrue(oa.Is_Active__c);
    Assert.areEqual(
      'OK (200 OK)',
      oa.Webhook_Status__c,
      'Webhook test ran after the save'
    );
    Assert.areEqual(
      LineTestFactory.SECRET_A,
      LineCredentialStore.getSecret(LineTestFactory.CHANNEL_A)
    );

    String expectedUrl = SITE + LineNamespace.webhookPath();
    Assert.areEqual(expectedUrl, result.webhookUrl);
    Map<String, Object> putBody = (Map<String, Object>) JSON.deserializeUntyped(
      mock.requestsTo('/webhook/endpoint')[0].getBody()
    );
    Assert.areEqual(expectedUrl, putBody.get('endpoint'));
    Assert.areEqual(oa.Id, result.oaConfigId);
  }

  @IsTest
  static void resultNeverContainsTheSecret() {
    LineTestFactory.ensurePackageAccess();
    Test.setMock(HttpCalloutMock.class, new LineHttpMock());
    Test.startTest();
    LineOAConfigAdminService.RegistrationResult result = LineOAConfigAdminService.registerOA(
      LineTestFactory.CHANNEL_A,
      LineTestFactory.SECRET_A,
      UserInfo.getUserId()
    );
    Test.stopTest();

    String serialized = JSON.serialize(result);
    Assert.isFalse(serialized.contains(LineTestFactory.SECRET_A));
    Assert.isFalse(serialized.contains(LineHttpMock.FAKE_TOKEN));
  }

  @IsTest
  static void reRegisteringUpdatesTheSameRecord() {
    LineTestFactory.ensurePackageAccess();
    Test.setMock(HttpCalloutMock.class, new LineHttpMock());
    LineTestFactory.createOA(
      LineTestFactory.CHANNEL_A,
      'Uold',
      'old_fake_secret',
      UserInfo.getUserId()
    );

    Test.startTest();
    LineOAConfigAdminService.registerOA(
      LineTestFactory.CHANNEL_A,
      LineTestFactory.SECRET_A,
      UserInfo.getUserId()
    );
    Test.stopTest();

    Assert.areEqual(
      1,
      [
        SELECT COUNT()
        FROM LINE_OA_Configuration__c
        WITH SYSTEM_MODE
      ]
    );
    Assert.areEqual(
      'Ubot_a',
      [
        SELECT Bot_User_Id__c
        FROM LINE_OA_Configuration__c
        WITH SYSTEM_MODE
      ]
      .Bot_User_Id__c
    );
    Assert.areEqual(
      LineTestFactory.SECRET_A,
      LineCredentialStore.getSecret(LineTestFactory.CHANNEL_A)
    );
  }

  @IsTest
  static void badCredentialsSaveNothing() {
    LineTestFactory.ensurePackageAccess();
    LineHttpMock mock = new LineHttpMock();
    mock.stub(
      'POST',
      '/oauth2/v3/token',
      400,
      '{"error":"invalid_client","error_description":"invalid client"}'
    );
    Test.setMock(HttpCalloutMock.class, mock);

    Test.startTest();
    try {
      LineOAConfigAdminService.registerOA(
        LineTestFactory.CHANNEL_A,
        'wrong_fake_secret',
        UserInfo.getUserId()
      );
      Assert.fail('Expected LineApiException');
    } catch (LineApiException e) {
      Assert.isTrue(e.isCredentialError());
      Assert.isFalse(e.getMessage().contains('wrong_fake_secret'));
    }
    Test.stopTest();

    Assert.areEqual(
      0,
      [
        SELECT COUNT()
        FROM LINE_OA_Configuration__c
        WITH SYSTEM_MODE
      ]
    );
    Assert.isNull(LineCredentialStore.getSecret(LineTestFactory.CHANNEL_A));
    Assert.areEqual(0, mock.requestsTo('/webhook/endpoint').size());
  }

  @IsTest
  static void missingSiteUrlIsRefusedBeforeAnyCallout() {
    LineTestFactory.ensurePackageAccess();
    delete as system [
      SELECT Id
      FROM LINE_Settings__c
      WITH SYSTEM_MODE
    ];
    LineSettings.reset();
    LineHttpMock mock = new LineHttpMock();
    Test.setMock(HttpCalloutMock.class, mock);

    try {
      LineOAConfigAdminService.registerOA(
        LineTestFactory.CHANNEL_A,
        LineTestFactory.SECRET_A,
        UserInfo.getUserId()
      );
      Assert.fail('Expected AdminException');
    } catch (LineOAConfigAdminService.AdminException e) {
      Assert.areEqual(System.Label.LINE_Error_Site_Url_Missing, e.getMessage());
    }
    Assert.areEqual(0, mock.requests.size());
  }

  @IsTest
  static void inactiveOrMissingRepIsRefused() {
    LineTestFactory.ensurePackageAccess();
    Test.setMock(HttpCalloutMock.class, new LineHttpMock());
    try {
      LineOAConfigAdminService.registerOA(
        LineTestFactory.CHANNEL_A,
        LineTestFactory.SECRET_A,
        null
      );
      Assert.fail('Expected AdminException');
    } catch (LineOAConfigAdminService.AdminException e) {
      Assert.areEqual(System.Label.LINE_Error_Rep_Inactive, e.getMessage());
    }
    Assert.areEqual(
      0,
      [
        SELECT COUNT()
        FROM LINE_OA_Configuration__c
        WITH SYSTEM_MODE
      ]
    );
  }

  // ---------- credentials (DEC-33) ----------

  private static Integer storedSecrets() {
    return [SELECT COUNT() FROM LINE_OA_Credential__c WITH SYSTEM_MODE];
  }

  @IsTest
  static void registrationMarksCredentialsValid() {
    LineTestFactory.ensurePackageAccess();
    Test.setMock(HttpCalloutMock.class, new LineHttpMock());

    Test.startTest();
    LineOAConfigAdminService.registerOA(
      LineTestFactory.CHANNEL_A,
      LineTestFactory.SECRET_A,
      UserInfo.getUserId()
    );
    Test.stopTest();

    LINE_OA_Configuration__c oa = [
      SELECT Credential_Status__c, Credential_Checked_At__c
      FROM LINE_OA_Configuration__c
      WITH SYSTEM_MODE
    ];
    Assert.areEqual('Valid', oa.Credential_Status__c);
    Assert.isNotNull(oa.Credential_Checked_At__c);
  }

  @IsTest
  static void removeDeletesTheSecretAndKeepsTheHistory() {
    LineTestFactory.ensurePackageAccess();
    LINE_OA_Configuration__c oa = LineTestFactory.createOA(
      LineTestFactory.CHANNEL_A,
      LineTestFactory.BOT_A,
      LineTestFactory.SECRET_A,
      UserInfo.getUserId()
    );
    insert as system new LINE_Conversation__c(
      Name = 'Somchai',
      LINE_OA_Configuration__c = oa.Id,
      LINE_User_Id__c = 'Ucustomer1',
      Unique_Key__c = LineTestFactory.CHANNEL_A + ':Ucustomer1'
    );
    Assert.areEqual(1, storedSecrets());

    Test.startTest();
    LineOAConfigAdminService.removeOA(oa.Id);
    Test.stopTest();

    Assert.areEqual(0, storedSecrets(), 'The secret is gone');
    LINE_OA_Configuration__c after = [
      SELECT Is_Active__c, Credential_Status__c, Credential_Checked_At__c
      FROM LINE_OA_Configuration__c
      WHERE Id = :oa.Id
      WITH SYSTEM_MODE
    ];
    Assert.isFalse(after.Is_Active__c);
    Assert.areEqual('Removed', after.Credential_Status__c);
    Assert.isNotNull(after.Credential_Checked_At__c);
    Assert.areEqual(
      1,
      [SELECT COUNT() FROM LINE_Conversation__c WITH SYSTEM_MODE],
      'Conversations stay as history'
    );
  }

  @IsTest
  static void removingAnUnknownOAFails() {
    LineTestFactory.ensurePackageAccess();
    for (Id unknown : new List<Id>{ null, UserInfo.getUserId() }) {
      try {
        LineOAConfigAdminService.removeOA(unknown);
        Assert.fail('Expected AdminException for ' + unknown);
      } catch (LineOAConfigAdminService.AdminException e) {
        Assert.areEqual(System.Label.LINE_Error_OA_Not_Found, e.getMessage());
      }
    }
  }

  @IsTest
  static void registeringARemovedOAAgainRestoresIt() {
    LineTestFactory.ensurePackageAccess();
    LINE_OA_Configuration__c removed = LineTestFactory.newOAConfig(
      LineTestFactory.CHANNEL_A,
      LineTestFactory.BOT_A,
      UserInfo.getUserId()
    );
    removed.Is_Active__c = false;
    removed.Credential_Status__c = 'Removed';
    insert as system removed;
    Test.setMock(HttpCalloutMock.class, new LineHttpMock());

    Test.startTest();
    LineOAConfigAdminService.registerOA(
      LineTestFactory.CHANNEL_A,
      LineTestFactory.SECRET_A,
      UserInfo.getUserId()
    );
    Test.stopTest();

    LINE_OA_Configuration__c after = [
      SELECT Is_Active__c, Credential_Status__c
      FROM LINE_OA_Configuration__c
      WHERE Id = :removed.Id
      WITH SYSTEM_MODE
    ];
    Assert.isTrue(after.Is_Active__c);
    Assert.areEqual('Valid', after.Credential_Status__c);
    Assert.areEqual(1, storedSecrets());
  }
}
