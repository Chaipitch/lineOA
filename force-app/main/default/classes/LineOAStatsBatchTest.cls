@IsTest
private class LineOAStatsBatchTest {
  @TestSetup
  static void setup() {
    LineTestFactory.ensurePackageAccess();
    User rep = LineTestFactory.createUser(new List<String>{ 'LINE_Chat_User' });
    LineTestFactory.createOA(
      LineTestFactory.CHANNEL_A,
      LineTestFactory.BOT_A,
      LineTestFactory.SECRET_A,
      rep.Id
    );
    LineTestFactory.createOA(
      LineTestFactory.CHANNEL_B,
      LineTestFactory.BOT_B,
      LineTestFactory.SECRET_B,
      rep.Id
    );
  }

  // ---------- helpers ----------

  private static LINE_OA_Configuration__c oa(String channelId) {
    return [
      SELECT
        Id,
        Channel_Id__c,
        Connected_Customers__c,
        Active_Followers__c,
        Blocked_Customers__c,
        Messages_Exchanged__c,
        Stats_Updated_At__c
      FROM LINE_OA_Configuration__c
      WHERE Channel_Id__c = :channelId
      WITH SYSTEM_MODE
    ];
  }

  private static LINE_Conversation__c conversation(
    LINE_OA_Configuration__c oa,
    String lineUserId,
    Id contactId
  ) {
    return new LINE_Conversation__c(
      Name = lineUserId,
      LINE_OA_Configuration__c = oa.Id,
      LINE_User_Id__c = lineUserId,
      Unique_Key__c = oa.Channel_Id__c + ':' + lineUserId,
      Contact__c = contactId,
      Status__c = 'Following'
    );
  }

  private static LINE_Message__c message(
    Id conversationId,
    String direction,
    String status
  ) {
    return new LINE_Message__c(
      LINE_Conversation__c = conversationId,
      Direction__c = direction,
      Message_Type__c = 'text',
      Text__c = 'hello',
      Status__c = status,
      Sent_At__c = Datetime.now()
    );
  }

  private static List<Contact> contacts(Integer count) {
    List<Contact> result = new List<Contact>();
    for (Integer i = 0; i < count; i++) {
      result.add(new Contact(LastName = 'Customer ' + i));
    }
    insert as system result;
    return result;
  }

  private static void run() {
    Test.startTest();
    Database.executeBatch(new LineOAStatsBatch(), LineOAStatsBatch.BATCH_SIZE);
    Test.stopTest();
  }

  // ---------- tests ----------

  @IsTest
  static void countsCustomersAndMessagesPerOA() {
    LineTestFactory.ensurePackageAccess();
    LINE_OA_Configuration__c oaA = oa(LineTestFactory.CHANNEL_A);
    LINE_OA_Configuration__c oaB = oa(LineTestFactory.CHANNEL_B);
    List<Contact> people = contacts(2);
    LINE_Conversation__c following = conversation(
      oaA,
      'Ufollowing',
      people[0].Id
    );
    LINE_Conversation__c blocked = conversation(oaA, 'Ublocked', people[1].Id);
    blocked.Status__c = 'Unfollowed';
    LINE_Conversation__c unlinked = conversation(oaA, 'Uunlinked', null);
    // The same customer on OA B counts for OA B as well.
    LINE_Conversation__c onB = conversation(oaB, 'Ufollowing', people[0].Id);
    insert as system new List<LINE_Conversation__c>{
      following,
      blocked,
      unlinked,
      onB
    };
    insert as system new List<LINE_Message__c>{
      message(following.Id, 'Inbound', 'Received'),
      message(following.Id, 'Outbound', 'Sent'),
      message(following.Id, 'Outbound', 'Failed'),
      message(following.Id, 'Inbound', 'Too Large'),
      message(blocked.Id, 'Inbound', 'Received'),
      message(unlinked.Id, 'Inbound', 'Received'),
      message(onB.Id, 'Outbound', 'Sent')
    };

    run();

    LINE_OA_Configuration__c a = oa(LineTestFactory.CHANNEL_A);
    Assert.areEqual(2, a.Connected_Customers__c, 'Linked, any status');
    Assert.areEqual(1, a.Active_Followers__c, 'Linked and following');
    Assert.areEqual(1, a.Blocked_Customers__c, 'Linked and blocked');
    Assert.areEqual(
      5,
      a.Messages_Exchanged__c,
      'Both directions, unlinked chats too, failed sends not'
    );
    Assert.isNotNull(a.Stats_Updated_At__c);
    LINE_OA_Configuration__c b = oa(LineTestFactory.CHANNEL_B);
    Assert.areEqual(1, b.Connected_Customers__c);
    Assert.areEqual(1, b.Messages_Exchanged__c);
  }

  @IsTest
  static void anOAWithNothingGetsZerosNotBlanks() {
    LineTestFactory.ensurePackageAccess();

    run();

    LINE_OA_Configuration__c b = oa(LineTestFactory.CHANNEL_B);
    Assert.areEqual(0, b.Connected_Customers__c);
    Assert.areEqual(0, b.Active_Followers__c);
    Assert.areEqual(0, b.Blocked_Customers__c);
    Assert.areEqual(0, b.Messages_Exchanged__c);
    Assert.isNotNull(b.Stats_Updated_At__c);
  }

  @IsTest
  static void recountsInsteadOfAdding() {
    LineTestFactory.ensurePackageAccess();
    LINE_OA_Configuration__c a = oa(LineTestFactory.CHANNEL_A);
    LINE_Conversation__c c = conversation(a, 'Ucustomer1', contacts(1)[0].Id);
    insert as system c;
    insert as system message(c.Id, 'Inbound', 'Received');
    update as system new LINE_OA_Configuration__c(
      Id = a.Id,
      Connected_Customers__c = 40,
      Messages_Exchanged__c = 900
    );

    run();

    a = oa(LineTestFactory.CHANNEL_A);
    Assert.areEqual(1, a.Connected_Customers__c, 'Last run is replaced');
    Assert.areEqual(1, a.Messages_Exchanged__c, 'Last run is replaced');
  }

  @IsTest
  static void totalsCarryAcrossExecutes() {
    LineTestFactory.ensurePackageAccess();
    LINE_OA_Configuration__c oaA = oa(LineTestFactory.CHANNEL_A);
    Integer customers = LineOAStatsBatch.BATCH_SIZE * 2 + 10;
    List<Contact> people = contacts(customers);
    List<LINE_Conversation__c> conversations = new List<LINE_Conversation__c>();
    for (Integer i = 0; i < customers; i++) {
      LINE_Conversation__c c = conversation(oaA, 'Ucustomer' + i, people[i].Id);
      if (Math.mod(i, 2) == 1) {
        c.Status__c = 'Unfollowed';
      }
      conversations.add(c);
    }
    insert as system conversations;
    List<LINE_Message__c> messages = new List<LINE_Message__c>();
    for (LINE_Conversation__c c : conversations) {
      messages.add(message(c.Id, 'Inbound', 'Received'));
      messages.add(message(c.Id, 'Outbound', 'Sent'));
    }
    insert as system messages;

    // A test can run only one execute of a batch, so the chunks are fed by hand, as the platform would.
    LineOAStatsBatch batch = new LineOAStatsBatch();
    Test.startTest();
    for (Integer i = 0; i < customers; i += LineOAStatsBatch.BATCH_SIZE) {
      List<LINE_Conversation__c> chunk = new List<LINE_Conversation__c>();
      for (
        Integer j = i;
        j < Math.min(i + LineOAStatsBatch.BATCH_SIZE, customers);
        j++
      ) {
        chunk.add(conversations[j]);
      }
      batch.execute(null, chunk);
    }
    batch.finish(null);
    Test.stopTest();

    LINE_OA_Configuration__c a = oa(LineTestFactory.CHANNEL_A);
    Assert.areEqual(customers, a.Connected_Customers__c);
    Assert.areEqual(customers / 2, a.Active_Followers__c);
    Assert.areEqual(customers / 2, a.Blocked_Customers__c);
    Assert.areEqual(customers * 2, a.Messages_Exchanged__c);
  }

  @IsTest
  static void aFailedCountSavesNothingAndIsLogged() {
    LineTestFactory.ensurePackageAccess();
    LINE_OA_Configuration__c oaA = oa(LineTestFactory.CHANNEL_A);
    update as system new LINE_OA_Configuration__c(
      Id = oaA.Id,
      Connected_Customers__c = 7
    );
    LineOAStatsBatch batch = new LineOAStatsBatch();
    batch.failed = true;

    Test.startTest();
    batch.finish(null);
    Test.stopTest();

    LINE_OA_Configuration__c a = oa(LineTestFactory.CHANNEL_A);
    Assert.areEqual(7, a.Connected_Customers__c, 'Previous numbers stay');
    Assert.isNull(a.Stats_Updated_At__c);
    Assert.areEqual(
      1,
      [
        SELECT COUNT()
        FROM LINE_Error_Log__c
        WHERE Source__c = 'LineOAStatsBatch.finish'
        WITH SYSTEM_MODE
      ]
    );
  }
}
