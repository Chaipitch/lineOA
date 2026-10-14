/**
 * Rotating an OA's channel secret (R7, DEC-45). The OA is created in @TestSetup because a test can't make the token
 * callout after DML in the same transaction. All secrets here are fake.
 */
@IsTest
private class LineSecretRotationTest {
  private static final String NEW_FAKE_SECRET = 'rotated_fake_secret';

  @TestSetup
  static void setup() {
    LineTestFactory.ensurePackageAccess();
    LineTestFactory.createOA(
      LineTestFactory.CHANNEL_A,
      LineTestFactory.BOT_A,
      LineTestFactory.SECRET_A,
      UserInfo.getUserId()
    );
  }

  private static LINE_OA_Configuration__c oa() {
    return [
      SELECT Id, Credential_Status__c, Credential_Checked_At__c
      FROM LINE_OA_Configuration__c
      WITH SYSTEM_MODE
      LIMIT 1
    ];
  }

  @IsTest
  static void newSecretIsCheckedWithLineThenStored() {
    LineTestFactory.ensurePackageAccess();
    LineHttpMock mock = new LineHttpMock();
    Test.setMock(HttpCalloutMock.class, mock);

    Test.startTest();
    LineOAConfigAdminService.rotateSecret(
      oa().Id,
      '  ' + NEW_FAKE_SECRET + ' '
    );
    Test.stopTest();

    Assert.areEqual(
      NEW_FAKE_SECRET,
      LineCredentialStore.getSecret(LineTestFactory.CHANNEL_A),
      'Stored, trimmed'
    );
    String tokenRequest = mock.requestsTo('/oauth2/v3/token')[0].getBody();
    Assert.isTrue(
      tokenRequest.contains('client_secret=' + NEW_FAKE_SECRET),
      'LINE was asked with the new secret, not a cached token from the old one'
    );
    Assert.areEqual('Valid', oa().Credential_Status__c);
    Assert.isNotNull(oa().Credential_Checked_At__c);
  }

  @IsTest
  static void aSecretLineRejectsChangesNothing() {
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
      LineOAConfigAdminService.rotateSecret(oa().Id, 'mistyped_fake_secret');
      Assert.fail('Expected LineApiException');
    } catch (LineApiException e) {
      Assert.isTrue(e.isCredentialError());
      Assert.isFalse(e.getMessage().contains('mistyped_fake_secret'));
    }
    Test.stopTest();

    Assert.areEqual(
      LineTestFactory.SECRET_A,
      LineCredentialStore.getSecret(LineTestFactory.CHANNEL_A),
      'The old secret stays'
    );
  }

  @IsTest
  static void blankSecretAndRemovedOaAreRefusedBeforeAnyCallout() {
    LineTestFactory.ensurePackageAccess();
    LineHttpMock mock = new LineHttpMock();
    Test.setMock(HttpCalloutMock.class, mock);
    Id oaId = oa().Id;

    try {
      LineOAConfigAdminService.rotateSecret(oaId, '  ');
      Assert.fail('Expected AdminException');
    } catch (LineOAConfigAdminService.AdminException e) {
      Assert.areEqual(System.Label.LINE_Error_Secret_Required, e.getMessage());
    }
    LineOAConfigAdminService.removeOA(oaId);
    try {
      LineOAConfigAdminService.rotateSecret(oaId, NEW_FAKE_SECRET);
      Assert.fail('Expected AdminException');
    } catch (LineOAConfigAdminService.AdminException e) {
      Assert.areEqual(System.Label.LINE_Error_Rotate_Removed, e.getMessage());
    }
    try {
      LineOAConfigAdminService.rotateSecret(null, NEW_FAKE_SECRET);
      Assert.fail('Expected AdminException');
    } catch (LineOAConfigAdminService.AdminException e) {
      Assert.areEqual(System.Label.LINE_Error_OA_Not_Found, e.getMessage());
    }
    Assert.areEqual(0, mock.requests.size());
  }

  @IsTest
  static void onlyAdminsCanRotate() {
    LineTestFactory.ensurePackageAccess();
    User rep = LineTestFactory.createUser(new List<String>{ 'LINE_Chat_User' });
    Id oaId = oa().Id;

    String message;
    System.runAs(rep) {
      try {
        LineAdminController.rotateSecret(oaId, NEW_FAKE_SECRET);
      } catch (AuraHandledException e) {
        message = e.getMessage();
      }
    }
    Assert.isNotNull(message, 'Refused');
    Assert.areEqual(
      LineTestFactory.SECRET_A,
      LineCredentialStore.getSecret(LineTestFactory.CHANNEL_A)
    );
  }
}
