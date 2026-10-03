@IsTest
private class LineOAConfigTriggerHandlerTest {
  private static Integer storedSecrets() {
    return [SELECT COUNT() FROM LINE_OA_Credential__c WITH SYSTEM_MODE];
  }

  private static LINE_OA_Configuration__c oa(String channelId, String botId) {
    return LineTestFactory.createOA(
      channelId,
      botId,
      'fake_secret_' + channelId,
      UserInfo.getUserId()
    );
  }

  @IsTest
  static void deletingOAsDeletesTheirSecrets() {
    LineTestFactory.ensurePackageAccess();
    List<LINE_OA_Configuration__c> oas = new List<LINE_OA_Configuration__c>{
      oa(LineTestFactory.CHANNEL_A, LineTestFactory.BOT_A),
      oa(LineTestFactory.CHANNEL_B, LineTestFactory.BOT_B)
    };
    Assert.areEqual(2, storedSecrets());

    Test.startTest();
    delete as system oas;
    Test.stopTest();

    Assert.areEqual(0, storedSecrets(), 'No secret outlives its OA');
  }

  @IsTest
  static void anOAWithConversationsCannotBeDeletedSoItsSecretStays() {
    LineTestFactory.ensurePackageAccess();
    LINE_OA_Configuration__c withHistory = oa(
      LineTestFactory.CHANNEL_A,
      LineTestFactory.BOT_A
    );
    insert as system new LINE_Conversation__c(
      Name = 'Somchai',
      LINE_OA_Configuration__c = withHistory.Id,
      LINE_User_Id__c = 'Ucustomer1',
      Unique_Key__c = LineTestFactory.CHANNEL_A + ':Ucustomer1'
    );

    Test.startTest();
    Database.DeleteResult result = Database.delete(
      withHistory,
      false,
      AccessLevel.SYSTEM_MODE
    );
    Test.stopTest();

    Assert.isFalse(result.isSuccess(), 'Conversations block the delete');
    Assert.areEqual(1, storedSecrets());
  }

  @IsTest
  static void bypassedHandlerLeavesSecrets() {
    LineTestFactory.ensurePackageAccess();
    LINE_OA_Configuration__c one = oa(
      LineTestFactory.CHANNEL_A,
      LineTestFactory.BOT_A
    );
    LineTriggerHandler.bypass('LineOAConfigTriggerHandler');

    Test.startTest();
    delete as system one;
    Test.stopTest();

    Assert.areEqual(1, storedSecrets());
    LineTriggerHandler.clearBypass('LineOAConfigTriggerHandler');
  }
}
