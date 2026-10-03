@IsTest
private class LineDailyEventSyncBatchTest {
  private static final String CUSTOMER = 'Ucustomer1';

  @TestSetup
  static void setup() {
    LineTestFactory.ensurePackageAccess();
    User rep = LineTestFactory.createUser(new List<String>{ 'LINE_Chat_User' });
    LINE_OA_Configuration__c oa = LineTestFactory.createOA(
      LineTestFactory.CHANNEL_A,
      LineTestFactory.BOT_A,
      LineTestFactory.SECRET_A,
      rep.Id
    );
    Account acme = new Account(Name = 'Acme');
    insert as system acme;
    Contact somchai = new Contact(
      LastName = 'Somchai',
      AccountId = acme.Id,
      LINE_User_Id__c = CUSTOMER
    );
    insert as system somchai;
    insert as system conversation(oa.Id, CUSTOMER, somchai.Id, rep.Id);
  }

  // ---------- helpers ----------

  private static LINE_Conversation__c conversation(
    Id oaId,
    String lineUserId,
    Id contactId,
    Id ownerId
  ) {
    return new LINE_Conversation__c(
      Name = lineUserId,
      LINE_OA_Configuration__c = oaId,
      LINE_User_Id__c = lineUserId,
      Unique_Key__c = LineTestFactory.CHANNEL_A + ':' + lineUserId,
      Contact__c = contactId,
      OwnerId = ownerId,
      Last_Message_At__c = Datetime.now()
    );
  }

  private static LINE_Conversation__c theConversation() {
    return [
      SELECT Id, OwnerId, LINE_OA_Configuration__c, Contact__c
      FROM LINE_Conversation__c
      WHERE LINE_User_Id__c = :CUSTOMER
      WITH SYSTEM_MODE
    ];
  }

  private static User rep() {
    return [
      SELECT Id, FirstName, Name, TimeZoneSidKey
      FROM User
      WHERE Id = :theConversation().OwnerId
      WITH SYSTEM_MODE
    ];
  }

  private static Date yesterday() {
    return LineDailyEventSyncBatch.today(LineDailyEventSyncBatch.orgTimeZone())
      .addDays(-1);
  }

  private static Datetime at(Date day, Integer hour, Integer minute) {
    return LineDailyEventSyncBatch.startOfDay(
        day,
        LineDailyEventSyncBatch.orgTimeZone()
      )
      .addHours(hour)
      .addMinutes(minute);
  }

  private static LINE_Message__c inbound(
    Id conversationId,
    String text,
    Datetime sentAt
  ) {
    return new LINE_Message__c(
      LINE_Conversation__c = conversationId,
      Direction__c = 'Inbound',
      Message_Type__c = 'text',
      Text__c = text,
      Status__c = 'Received',
      Sent_At__c = sentAt
    );
  }

  private static LINE_Message__c outbound(
    Id conversationId,
    String text,
    Datetime sentAt,
    Id senderId
  ) {
    return new LINE_Message__c(
      LINE_Conversation__c = conversationId,
      Direction__c = 'Outbound',
      Message_Type__c = 'text',
      Text__c = text,
      Status__c = 'Sent',
      Sent_At__c = sentAt,
      Sender__c = senderId
    );
  }

  // 2.8's own example: three messages on one day, plus one either side of it that must be left out.
  private static void insertExampleDay(Id conversationId, Id repId) {
    Date day = yesterday();
    insert as system new List<LINE_Message__c>{
      inbound(
        conversationId,
        'Could you send the revised quotation?',
        at(day, 10, 1)
      ),
      outbound(
        conversationId,
        'Sure, I will send it today.',
        at(day, 10, 3),
        repId
      ),
      new LINE_Message__c(
        LINE_Conversation__c = conversationId,
        Direction__c = 'Inbound',
        Message_Type__c = 'sticker',
        Status__c = 'Received',
        Sent_At__c = at(day, 10, 8)
      ),
      inbound(conversationId, 'the day before', at(day.addDays(-1), 23, 59)),
      inbound(conversationId, 'the day after', at(day.addDays(1), 0, 0))
    };
  }

  private static List<LINE_Conversation__c> scope() {
    return [
      SELECT
        Id,
        OwnerId,
        Contact__c,
        Contact__r.Name,
        Contact__r.AccountId,
        LINE_OA_Configuration__r.Name
      FROM LINE_Conversation__c
      WHERE Contact__c != NULL
      WITH SYSTEM_MODE
    ];
  }

  private static List<Event> lineEvents() {
    return [
      SELECT
        Id,
        Subject,
        WhoId,
        WhatId,
        OwnerId,
        LINE_Conversation__c,
        LINE_Sync_Key__c,
        StartDateTime,
        EndDateTime,
        ShowAs,
        Description
      FROM Event
      WHERE LINE_Conversation__c != NULL
      WITH SYSTEM_MODE
      ORDER BY CreatedDate
    ];
  }

  private static void run(Date day) {
    Test.startTest();
    Database.executeBatch(new LineDailyEventSyncBatch(day), 200);
    Test.stopTest();
  }

  // ---------- the Event (2.8, DEC-28) ----------

  @IsTest
  static void oneEventPerConversationWithTheDaysTranscript() {
    LineTestFactory.ensurePackageAccess();
    LINE_Conversation__c c = theConversation();
    User rep = rep();
    insertExampleDay(c.Id, rep.Id);

    run(yesterday());

    List<Event> events = lineEvents();
    Assert.areEqual(1, events.size(), 'One Event for the day');
    Event e = events[0];
    Contact somchai = [
      SELECT Name, AccountId
      FROM Contact
      WHERE Id = :c.Contact__c
      WITH SYSTEM_MODE
    ];
    Assert.areEqual(somchai.Id, e.WhoId, 'Who = the Contact');
    Assert.areEqual(
      somchai.AccountId,
      e.WhatId,
      'What = the Contact\'s Account'
    );
    Assert.areEqual(c.Id, e.LINE_Conversation__c, 'Linked to the conversation');
    Assert.areEqual(rep.Id, e.OwnerId, 'Owned by the rep');
    Assert.areEqual(
      String.format(
        System.Label.LINE_Event_Subject,
        new List<Object>{ 'Somchai', 'OA ' + LineTestFactory.CHANNEL_A }
      ),
      e.Subject
    );
    Assert.areEqual(at(yesterday(), 10, 1), e.StartDateTime, 'First message');
    Assert.areEqual(at(yesterday(), 10, 8), e.EndDateTime, 'Last message');
    Assert.areEqual('Free', e.ShowAs, 'Does not block the rep\'s calendar');
    Assert.isTrue(e.LINE_Sync_Key__c.startsWith(c.Id + ':'));

    List<String> lines = e.Description.split('\n');
    Assert.areEqual(3, lines.size(), 'Only that day: ' + e.Description);
    String speaker = String.isBlank(rep.FirstName) ? rep.Name : rep.FirstName;
    String zone = rep.TimeZoneSidKey;
    Assert.areEqual(
      at(yesterday(), 10, 1).format('HH:mm', zone) +
        ' ' +
        System.Label.LINE_Event_Customer +
        ': Could you send the revised quotation?',
      lines[0]
    );
    Assert.areEqual(
      at(yesterday(), 10, 3).format('HH:mm', zone) +
        ' ' +
        speaker +
        ': Sure, I will send it today.',
      lines[1]
    );
    Assert.isTrue(
      lines[2].endsWith(': ' + System.Label.LINE_Preview_Sticker),
      lines[2]
    );
  }

  @IsTest
  static void rerunRebuildsTheSameEvent() {
    LineTestFactory.ensurePackageAccess();
    LINE_Conversation__c c = theConversation();
    insertExampleDay(c.Id, rep().Id);
    // First run, called directly so the batch can run again below.
    new LineDailyEventSyncBatch(yesterday()).execute(null, scope());
    Assert.areEqual(1, lineEvents().size());

    // A late message for the same day, then the nightly rerun.
    insert as system inbound(c.Id, 'Thank you.', at(yesterday(), 22, 0));
    run(yesterday());

    List<Event> events = lineEvents();
    Assert.areEqual(1, events.size(), 'A rerun never duplicates');
    Assert.areEqual(4, events[0].Description.split('\n').size());
    Assert.areEqual(
      at(yesterday(), 22, 0),
      events[0].EndDateTime,
      'Rebuilt with the late message'
    );
  }

  @IsTest
  static void contactWithoutAccountLeavesWhatBlank() {
    LineTestFactory.ensurePackageAccess();
    LINE_Conversation__c c = theConversation();
    Contact somchai = new Contact(Id = c.Contact__c, AccountId = null);
    update as system somchai;
    insertExampleDay(c.Id, rep().Id);

    run(yesterday());

    Assert.isNull(lineEvents()[0].WhatId);
  }

  // ---------- what is skipped ----------

  @IsTest
  static void unlinkedConversationGetsNoEvent() {
    LineTestFactory.ensurePackageAccess();
    LINE_Conversation__c c = theConversation();
    c.Contact__c = null;
    update as system c;
    insertExampleDay(c.Id, rep().Id);

    run(yesterday());

    Assert.areEqual(0, lineEvents().size());
  }

  @IsTest
  static void conversationWithNoMessagesThatDayGetsNoEvent() {
    LineTestFactory.ensurePackageAccess();
    LINE_Conversation__c c = theConversation();
    // Active since the start of the day (so the batch looks at it), but only after the day ended.
    insert as system inbound(
      c.Id,
      'today only',
      at(yesterday().addDays(1), 9, 0)
    );

    run(yesterday());

    Assert.areEqual(0, lineEvents().size());
  }

  @IsTest
  static void nothingHappensWhileDailySyncIsOff() {
    LineTestFactory.ensurePackageAccess();
    insert as system new LINE_Settings__c(
      SetupOwnerId = UserInfo.getOrganizationId(),
      Daily_Sync_Enabled__c = false
    );
    insertExampleDay(theConversation().Id, rep().Id);

    run(yesterday());

    Assert.areEqual(0, lineEvents().size());
  }

  // ---------- owners and failures ----------

  @IsTest
  static void queueOwnedConversationIsOwnedByTheRunningUser() {
    LineTestFactory.ensurePackageAccess();
    Group queue = new Group(Name = 'LINE Sync Test', Type = 'Queue');
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insert as system queue;
      insert as system new QueueSobject(
        QueueId = queue.Id,
        SobjectType = LineNamespace.apiPrefix() + 'LINE_Conversation__c'
      );
    }
    LINE_Conversation__c c = theConversation();
    c.OwnerId = queue.Id;
    update as system c;
    insertExampleDay(c.Id, null);

    run(yesterday());

    List<Event> events = lineEvents();
    Assert.areEqual(1, events.size());
    Assert.areEqual(UserInfo.getUserId(), events[0].OwnerId);
    Assert.isTrue(
      events[0].Description.split('\n')[1].contains(System.Label.LINE_App_Name),
      'An outbound message with no sender is attributed to the app'
    );
  }

  @IsTest
  static void rejectedEventIsLoggedAndTheOthersAreStillCreated() {
    LineTestFactory.ensurePackageAccess();
    LINE_Conversation__c c = theConversation();
    // A second customer whose Event will be rejected: owned by a rep who has since been deactivated.
    User leaver = LineTestFactory.createUser(
      new List<String>{ 'LINE_Chat_User' }
    );
    Contact other = new Contact(
      LastName = 'Niran',
      LINE_User_Id__c = 'Ucustomer2'
    );
    insert as system other;
    LINE_Conversation__c doomed = conversation(
      c.LINE_OA_Configuration__c,
      'Ucustomer2',
      other.Id,
      leaver.Id
    );
    insert as system doomed;
    insertExampleDay(c.Id, rep().Id);
    insertExampleDay(doomed.Id, null);
    // Stands in for any subscriber-side rejection: Salesforce refuses an Event owned by an inactive user.
    System.runAs(new User(Id = UserInfo.getUserId())) {
      leaver.IsActive = false;
      update as system leaver;
    }

    run(yesterday());

    List<Event> events = lineEvents();
    Assert.areEqual(
      1,
      events.size(),
      'The good conversation still gets its Event'
    );
    Assert.areEqual(c.Id, events[0].LINE_Conversation__c);
    Assert.areEqual(
      1,
      [
        SELECT COUNT()
        FROM LINE_Error_Log__c
        WHERE Source__c = 'LineDailyEventSyncBatch.insert'
        WITH SYSTEM_MODE
      ],
      'The rejection is logged, not thrown'
    );
  }

  // ---------- transcript details ----------

  @IsTest
  static void longDayIsTruncatedToTheFieldLimit() {
    LineTestFactory.ensurePackageAccess();
    LINE_Conversation__c c = theConversation();
    List<LINE_Message__c> messages = new List<LINE_Message__c>();
    for (Integer i = 0; i < 40; i++) {
      messages.add(inbound(c.Id, 'x'.repeat(1000), at(yesterday(), 8, i)));
    }
    insert as system messages;

    run(yesterday());

    Event e = lineEvents()[0];
    Assert.isTrue(
      e.Description.length() <= LineDailyEventSyncBatch.DESCRIPTION_LENGTH,
      'Fits the field: ' + e.Description.length()
    );
    Assert.isTrue(e.Description.endsWith(System.Label.LINE_Event_Truncated));
    Assert.areEqual(
      at(yesterday(), 8, 39),
      e.EndDateTime,
      'The time range still covers the whole day'
    );
  }

  @IsTest
  static void nonTextMessagesReadLikeTheChatPreviews() {
    LineTestFactory.ensurePackageAccess();
    Map<String, String> expected = new Map<String, String>{
      'image' => System.Label.LINE_Preview_Image,
      'video' => System.Label.LINE_Preview_Video,
      'audio' => System.Label.LINE_Preview_Audio,
      'sticker' => System.Label.LINE_Preview_Sticker,
      'unsupported' => System.Label.LINE_Preview_Unsupported
    };
    for (String type : expected.keySet()) {
      Assert.areEqual(
        expected.get(type),
        LineDailyEventSyncBatch.body(
          new LINE_Message__c(Message_Type__c = type)
        ),
        type
      );
    }
    Assert.isTrue(
      LineDailyEventSyncBatch.body(
          new LINE_Message__c(
            Message_Type__c = 'file',
            File_Name__c = 'quote.pdf'
          )
        )
        .contains('quote.pdf')
    );
    Assert.isTrue(
      LineDailyEventSyncBatch.body(
          new LINE_Message__c(
            Message_Type__c = 'location',
            Location__c = 'Office, Bangkok'
          )
        )
        .contains('Office, Bangkok')
    );
    Assert.areEqual(
      'a\nb',
      LineDailyEventSyncBatch.body(
        new LINE_Message__c(Message_Type__c = 'text', Text__c = 'a\r\nb')
      ),
      'Windows line endings are normalised'
    );
  }

  // ---------- bulk ----------

  @IsTest
  static void manyConversationsInOneRun() {
    LineTestFactory.ensurePackageAccess();
    LINE_Conversation__c first = theConversation();
    Integer total = 100;
    List<Contact> contacts = new List<Contact>();
    for (Integer i = 0; i < total; i++) {
      contacts.add(new Contact(LastName = 'Bulk ' + i));
    }
    insert as system contacts;
    List<LINE_Conversation__c> conversations = new List<LINE_Conversation__c>();
    for (Integer i = 0; i < total; i++) {
      conversations.add(
        conversation(
          first.LINE_OA_Configuration__c,
          'Ubulk' + i,
          contacts[i].Id,
          first.OwnerId
        )
      );
    }
    insert as system conversations;
    List<LINE_Message__c> messages = new List<LINE_Message__c>();
    for (LINE_Conversation__c c : conversations) {
      messages.add(inbound(c.Id, 'hello', at(yesterday(), 9, 0)));
      messages.add(inbound(c.Id, 'again', at(yesterday(), 9, 5)));
    }
    insert as system messages;

    run(yesterday());

    Assert.areEqual(total, lineEvents().size());
  }

  // ---------- days and time zones (DEC-30) ----------

  @IsTest
  static void defaultTargetIsYesterdayInTheOrgTimeZone() {
    LineTestFactory.ensurePackageAccess();
    Id conversationId = theConversation().Id;
    String yesterdayText = Datetime.newInstanceGmt(
        yesterday(),
        Time.newInstance(0, 0, 0, 0)
      )
      .formatGmt('yyyy-MM-dd');
    Assert.areEqual(
      conversationId + ':' + yesterdayText,
      new LineDailyEventSyncBatch().syncKey(conversationId)
    );
  }

  @IsTest
  static void dayStartsAtLocalMidnight() {
    LineTestFactory.ensurePackageAccess();
    Assert.areEqual(
      Datetime.newInstanceGmt(2026, 9, 27, 17, 0, 0),
      LineDailyEventSyncBatch.startOfDay(
        Date.newInstance(2026, 9, 28),
        TimeZone.getTimeZone('Asia/Bangkok')
      ),
      'UTC+7'
    );
    TimeZone newYork = TimeZone.getTimeZone('America/New_York');
    Assert.areEqual(
      Datetime.newInstanceGmt(2026, 3, 8, 5, 0, 0),
      LineDailyEventSyncBatch.startOfDay(Date.newInstance(2026, 3, 8), newYork),
      'Winter time on the day clocks go forward'
    );
    Assert.areEqual(
      Datetime.newInstanceGmt(2026, 11, 1, 4, 0, 0),
      LineDailyEventSyncBatch.startOfDay(
        Date.newInstance(2026, 11, 1),
        newYork
      ),
      'Summer time on the day clocks go back'
    );
  }

  // ---------- Event length (whole minutes) ----------

  @IsTest
  static void eventCoversItsMessagesToTheWholeMinute() {
    LineTestFactory.ensurePackageAccess();
    LINE_Conversation__c c = theConversation();
    insert as system new List<LINE_Message__c>{
      inbound(c.Id, 'first', at(yesterday(), 10, 1).addSeconds(30)),
      inbound(c.Id, 'last', at(yesterday(), 10, 8).addSeconds(20))
    };

    run(yesterday());

    Event e = lineEvents()[0];
    Assert.areEqual(at(yesterday(), 10, 1), e.StartDateTime, 'Rounded down');
    Assert.areEqual(
      at(yesterday(), 10, 9),
      e.EndDateTime,
      'Rounded up, so the last message is inside the Event'
    );
  }

  @IsTest
  static void roundingLeavesWholeMinutesAlone() {
    Datetime whole = Datetime.newInstanceGmt(2026, 9, 30, 2, 2, 0);
    Assert.areEqual(whole, LineDailyEventSyncBatch.floorToMinute(whole));
    Assert.areEqual(whole, LineDailyEventSyncBatch.ceilToMinute(whole));
    Datetime part = whole.addSeconds(33);
    Assert.areEqual(whole, LineDailyEventSyncBatch.floorToMinute(part));
    Assert.areEqual(
      whole.addMinutes(1),
      LineDailyEventSyncBatch.ceilToMinute(part)
    );
  }
}
