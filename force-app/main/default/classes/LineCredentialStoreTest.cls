@IsTest
private class LineCredentialStoreTest {
  @IsTest
  static void putThenGetReturnsSecret() {
    LineTestFactory.ensurePackageAccess();
    LineCredentialStore.putSecret(
      LineTestFactory.CHANNEL_A,
      LineTestFactory.SECRET_A
    );

    Assert.areEqual(
      LineTestFactory.SECRET_A,
      LineCredentialStore.getSecret(LineTestFactory.CHANNEL_A)
    );
    LINE_OA_Credential__c stored = LINE_OA_Credential__c.getInstance(
      LineTestFactory.CHANNEL_A
    );
    Assert.areEqual(
      LineTestFactory.SECRET_A,
      stored.Channel_Secret__c,
      'Stored in the protected setting'
    );
  }

  @IsTest
  static void putReplacesExistingSecret() {
    LineTestFactory.ensurePackageAccess();
    LineCredentialStore.putSecret(LineTestFactory.CHANNEL_A, 'old_fake_secret');
    LineCredentialStore.putSecret(LineTestFactory.CHANNEL_A, 'new_fake_secret');

    Assert.areEqual(
      'new_fake_secret',
      LineCredentialStore.getSecret(LineTestFactory.CHANNEL_A)
    );
    Assert.areEqual(
      1,
      [
        SELECT COUNT()
        FROM LINE_OA_Credential__c
        WHERE Name = :LineTestFactory.CHANNEL_A
        WITH SYSTEM_MODE
      ]
    );
  }

  @IsTest
  static void secretsAreKeptPerChannel() {
    LineTestFactory.ensurePackageAccess();
    LineTestFactory.putTestSecrets();
    Assert.areEqual(
      LineTestFactory.SECRET_A,
      LineCredentialStore.getSecret(LineTestFactory.CHANNEL_A)
    );
    Assert.areEqual(
      LineTestFactory.SECRET_B,
      LineCredentialStore.getSecret(LineTestFactory.CHANNEL_B)
    );
  }

  @IsTest
  static void unknownOrInvalidChannelReturnsNull() {
    LineTestFactory.ensurePackageAccess();
    Assert.isNull(LineCredentialStore.getSecret('1999999999'));
    Assert.isNull(LineCredentialStore.getSecret(null));
    Assert.isNull(LineCredentialStore.getSecret('not-a-channel'));
  }

  @IsTest
  static void removeDeletesSecret() {
    LineTestFactory.ensurePackageAccess();
    LineCredentialStore.putSecret(
      LineTestFactory.CHANNEL_A,
      LineTestFactory.SECRET_A
    );
    LineCredentialStore.remove(LineTestFactory.CHANNEL_A);
    LineCredentialStore.remove('not-a-channel');

    Assert.isNull(LineCredentialStore.getSecret(LineTestFactory.CHANNEL_A));
    Assert.areEqual(
      0,
      [
        SELECT COUNT()
        FROM LINE_OA_Credential__c
        WITH SYSTEM_MODE
      ]
    );
  }

  @IsTest
  static void invalidInputIsRejectedWithoutEchoingSecret() {
    LineTestFactory.ensurePackageAccess();
    for (
      String channelId : new List<String>{ null, '', 'abc', '1'.repeat(39) }
    ) {
      try {
        LineCredentialStore.putSecret(channelId, 'fake_secret_value');
        Assert.fail('Expected IllegalArgumentException for ' + channelId);
      } catch (IllegalArgumentException e) {
        Assert.isFalse(e.getMessage().contains('fake_secret_value'));
      }
    }
    for (String secret : new List<String>{ null, ' ', 'x'.repeat(256) }) {
      try {
        LineCredentialStore.putSecret(LineTestFactory.CHANNEL_A, secret);
        Assert.fail('Expected IllegalArgumentException');
      } catch (IllegalArgumentException e) {
        Assert.areEqual('Invalid channel secret.', e.getMessage());
      }
    }
    Assert.areEqual(
      0,
      [
        SELECT COUNT()
        FROM LINE_OA_Credential__c
        WITH SYSTEM_MODE
      ]
    );
  }

  @IsTest
  static void removeAllDeletesSeveralSecretsAtOnce() {
    LineTestFactory.ensurePackageAccess();
    LineTestFactory.putTestSecrets();
    Assert.areEqual(
      2,
      [SELECT COUNT() FROM LINE_OA_Credential__c WITH SYSTEM_MODE]
    );

    Test.startTest();
    LineCredentialStore.removeAll(
      new Set<String>{
        LineTestFactory.CHANNEL_A,
        LineTestFactory.CHANNEL_B,
        'not-a-channel',
        null
      }
    );
    Test.stopTest();

    Assert.areEqual(
      0,
      [SELECT COUNT() FROM LINE_OA_Credential__c WITH SYSTEM_MODE]
    );
    Assert.isNull(LineCredentialStore.getSecret(LineTestFactory.CHANNEL_A));
    LineCredentialStore.removeAll(null);
    LineCredentialStore.removeAll(new Set<String>());
  }
}
