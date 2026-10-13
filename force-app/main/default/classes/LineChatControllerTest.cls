@IsTest
private class LineChatControllerTest {
  @TestSetup
  static void setup() {
    LineTestFactory.ensurePackageAccess();
    User repA = LineTestFactory.createUser(
      new List<String>{ 'LINE_Chat_User' }
    );
    User repB = LineTestFactory.createUser(
      new List<String>{ 'LINE_Chat_User' }
    );
    LINE_OA_Configuration__c oa = LineTestFactory.createOA(
      LineTestFactory.CHANNEL_A,
      LineTestFactory.BOT_A,
      LineTestFactory.SECRET_A,
      repA.Id
    );
    insert as system new LINE_Conversation__c(
      Name = 'Somchai',
      LINE_OA_Configuration__c = oa.Id,
      LINE_User_Id__c = 'Ucustomer1',
      Unique_Key__c = LineTestFactory.CHANNEL_A + ':Ucustomer1',
      Status__c = 'Following',
      OwnerId = repA.Id
    );
    Assert.areNotEqual(null, repB.Id);
  }

  private static User repA() {
    return [
      SELECT Id
      FROM User
      WHERE Id IN (SELECT Assigned_Rep__c FROM LINE_OA_Configuration__c)
      WITH SYSTEM_MODE
      LIMIT 1
    ];
  }

  private static User repB() {
    return [
      SELECT Id
      FROM User
      WHERE
        Username LIKE 'line.test.%'
        AND Id NOT IN (SELECT Assigned_Rep__c FROM LINE_OA_Configuration__c)
      WITH SYSTEM_MODE
      LIMIT 1
    ];
  }

  private static Id conversationId() {
    return [SELECT Id FROM LINE_Conversation__c WITH SYSTEM_MODE LIMIT 1].Id;
  }

  // Links the conversation to a Contact and gives the Contact a primary OA, as linking does in M6.
  private static Contact linkContact(Boolean withPrimaryOa) {
    LINE_Conversation__c c = [
      SELECT Id, Contact__c, LINE_OA_Configuration__c
      FROM LINE_Conversation__c
      WITH SYSTEM_MODE
    ];
    // Owned by the rep: the panel only opens on a Contact the rep can already see.
    Contact contact = new Contact(LastName = 'Somchai', OwnerId = repA().Id);
    if (withPrimaryOa) {
      contact.LINE_OA_Configuration__c = c.LINE_OA_Configuration__c;
    }
    insert as system contact;
    c.Contact__c = contact.Id;
    update as system c;
    return contact;
  }

  private static List<LINE_Message__c> insertMessages(
    Id conversationId,
    Integer count
  ) {
    List<LINE_Message__c> messages = new List<LINE_Message__c>();
    Datetime base = Datetime.newInstance(2026, 9, 1, 8, 0, 0);
    for (Integer i = 0; i < count; i++) {
      messages.add(
        new LINE_Message__c(
          LINE_Conversation__c = conversationId,
          Direction__c = 'Inbound',
          Message_Type__c = 'text',
          Text__c = 'message ' + i,
          Status__c = 'Received',
          Webhook_Event_Id__c = 'evt' + i,
          Sent_At__c = base.addMinutes(i)
        )
      );
    }
    insert as system messages;
    return messages;
  }

  // ---------- getConversations ----------

  @IsTest
  static void conversationsOfAContactAreReturnedToItsRep() {
    LineTestFactory.ensurePackageAccess();
    Contact contact = linkContact(true);

    Test.startTest();
    List<LineChatController.ConversationView> views;
    System.runAs(repA()) {
      views = LineChatController.getConversations(contact.Id);
    }
    Test.stopTest();

    Assert.isNull(
      LineChatController.lastUnexpectedError,
      'Nothing should be swallowed as a generic error'
    );
    Assert.areEqual(1, views.size());
    LineChatController.ConversationView v = views[0];
    Assert.areEqual(conversationId(), v.id);
    Assert.areEqual('Somchai', v.name);
    Assert.areEqual('Following', v.status);
    Assert.areEqual(0, v.unreadCount);
    Assert.isTrue(v.isPrimaryOa, 'This OA is the Contact primary OA');
    Assert.isNotNull(v.oaName);
  }

  @IsTest
  static void primaryOaConversationComesFirst() {
    LineTestFactory.ensurePackageAccess();
    Contact contact = linkContact(false);
    LINE_Conversation__c first = [
      SELECT Id, LINE_OA_Configuration__c
      FROM LINE_Conversation__c
      WITH SYSTEM_MODE
    ];
    // A second OA, whose conversation is newer, but is the Contact's primary one.
    LINE_OA_Configuration__c oaB = LineTestFactory.createOA(
      LineTestFactory.CHANNEL_B,
      LineTestFactory.BOT_B,
      LineTestFactory.SECRET_B,
      repA().Id
    );
    insert as system new LINE_Conversation__c(
      Name = 'Somchai via B',
      LINE_OA_Configuration__c = oaB.Id,
      LINE_User_Id__c = 'Ucustomer1',
      Unique_Key__c = LineTestFactory.CHANNEL_B + ':Ucustomer1',
      Contact__c = contact.Id,
      OwnerId = repA().Id,
      Last_Message_At__c = Datetime.now()
    );
    update as system new Contact(
      Id = contact.Id,
      LINE_OA_Configuration__c = first.LINE_OA_Configuration__c
    );

    Test.startTest();
    List<LineChatController.ConversationView> views;
    System.runAs(repA()) {
      views = LineChatController.getConversations(contact.Id);
    }
    Test.stopTest();

    Assert.areEqual(2, views.size());
    Assert.isTrue(views[0].isPrimaryOa, 'Primary OA opens first');
    Assert.areEqual(first.Id, views[0].id);
  }

  @IsTest
  static void otherRepSeesNoConversations() {
    LineTestFactory.ensurePackageAccess();
    Contact contact = linkContact(true);

    Test.startTest();
    List<LineChatController.ConversationView> views;
    System.runAs(repB()) {
      views = LineChatController.getConversations(contact.Id);
    }
    Test.stopTest();

    Assert.isTrue(views.isEmpty(), 'Sharing hides Rep A conversations');
  }

  @IsTest
  static void nullContactReturnsEmptyList() {
    LineTestFactory.ensurePackageAccess();
    System.runAs(repA()) {
      Assert.isTrue(LineChatController.getConversations(null).isEmpty());
    }
  }

  // ---------- getMessages ----------

  @IsTest
  static void messagesComeBackOldestFirstWithPaging() {
    LineTestFactory.ensurePackageAccess();
    Id conversationId = conversationId();
    insertMessages(conversationId, 5);

    Test.startTest();
    LineChatController.MessagePage page;
    LineChatController.MessagePage older;
    System.runAs(repA()) {
      page = LineChatController.getMessages(conversationId, null, null, 3);
      older = LineChatController.getMessages(
        conversationId,
        page.messages[0].sentAt,
        page.messages[0].id,
        3
      );
    }
    Test.stopTest();

    Assert.areEqual(3, page.messages.size());
    Assert.isTrue(page.hasMore, 'Two older messages remain');
    Assert.areEqual(
      'message 2',
      page.messages[0].text,
      'Oldest of the page first'
    );
    Assert.areEqual('message 4', page.messages[2].text, 'Newest last');

    Assert.areEqual(2, older.messages.size());
    Assert.isFalse(older.hasMore);
    Assert.areEqual('message 0', older.messages[0].text);
    Assert.areEqual('message 1', older.messages[1].text);
  }

  @IsTest
  static void pageSizeIsCapped() {
    LineTestFactory.ensurePackageAccess();
    Id conversationId = conversationId();
    insertMessages(conversationId, 3);

    System.runAs(repA()) {
      Assert.areEqual(
        3,
        LineChatController.getMessages(conversationId, null, null, 999)
          .messages.size()
      );
      Assert.areEqual(
        3,
        LineChatController.getMessages(conversationId, null, null, null)
          .messages.size()
      );
    }
  }

  @IsTest
  static void messageViewCarriesDisplayFields() {
    LineTestFactory.ensurePackageAccess();
    Id conversationId = conversationId();
    insert as system new LINE_Message__c(
      LINE_Conversation__c = conversationId,
      Direction__c = 'Inbound',
      Message_Type__c = 'file',
      Status__c = 'Received',
      File_Name__c = 'quote.pdf',
      File_Size__c = 2048,
      Sent_At__c = Datetime.now()
    );

    LineChatController.MessageView view;
    System.runAs(repA()) {
      view = LineChatController.getMessages(conversationId, null, null, 10)
        .messages[0];
    }

    Assert.areEqual('file', view.messageType);
    Assert.areEqual('quote.pdf', view.fileName);
    Assert.areEqual(2048, view.fileSize);
    Assert.isFalse(view.isOutbound);
    Assert.isNull(view.stickerUrl, 'Only stickers carry a sticker picture');
  }

  @IsTest
  static void stickerMessageCarriesItsPictureUrl() {
    LineTestFactory.ensurePackageAccess();
    Id conversationId = conversationId();
    insert as system new LINE_Message__c(
      LINE_Conversation__c = conversationId,
      Direction__c = 'Inbound',
      Message_Type__c = 'sticker',
      Status__c = 'Received',
      Sticker_Package_Id__c = '446',
      Sticker_Id__c = '1988',
      Sent_At__c = Datetime.now()
    );

    LineChatController.MessageView view;
    System.runAs(repA()) {
      view = LineChatController.getMessages(conversationId, null, null, 10)
        .messages[0];
    }

    Assert.areEqual('1988', view.stickerId);
    Assert.areEqual(
      LineApiClient.stickerImageUrl('1988'),
      view.stickerUrl,
      'The panel gets the picture URL built on the server'
    );
  }

  @IsTest
  static void otherRepCannotReadMessages() {
    LineTestFactory.ensurePackageAccess();
    Id conversationId = conversationId();
    insertMessages(conversationId, 2);

    System.runAs(repB()) {
      try {
        LineChatController.getMessages(conversationId, null, null, 10);
        Assert.fail('Expected AuraHandledException');
      } catch (AuraHandledException e) {
        Assert.areEqual(System.Label.LINE_Error_No_Access, e.getMessage());
      }
    }
  }

  // ---------- getMessagesSince ----------

  @IsTest
  static void pollReturnsOnlyNewerMessages() {
    LineTestFactory.ensurePackageAccess();
    Id conversationId = conversationId();
    List<LINE_Message__c> all = insertMessages(conversationId, 4);
    LINE_Message__c third = [
      SELECT Id, Sent_At__c
      FROM LINE_Message__c
      WHERE Webhook_Event_Id__c = 'evt2'
      WITH SYSTEM_MODE
    ];

    Test.startTest();
    List<LineChatController.MessageView> since;
    List<LineChatController.MessageView> everything = new List<LineChatController.MessageView>();
    System.runAs(repA()) {
      since = LineChatController.getMessagesSince(
        conversationId,
        third.Sent_At__c,
        third.Id
      );
      everything = LineChatController.getMessagesSince(
        conversationId,
        null,
        null
      );
    }
    Test.stopTest();

    Assert.areEqual(1, since.size(), 'Only the message after the marker');
    Assert.areEqual('message 3', since[0].text);
    Assert.areEqual(4, everything.size(), 'No marker returns everything');
    Assert.areEqual('message 0', everything[0].text, 'Oldest first');
  }

  @IsTest
  static void pollOnAnotherRepConversationIsRefused() {
    LineTestFactory.ensurePackageAccess();
    Id conversationId = conversationId();
    System.runAs(repB()) {
      try {
        LineChatController.getMessagesSince(conversationId, null, null);
        Assert.fail('Expected AuraHandledException');
      } catch (AuraHandledException e) {
        Assert.areEqual(System.Label.LINE_Error_No_Access, e.getMessage());
      }
    }
  }

  // ---------- markRead and settings ----------

  @IsTest
  static void markReadClearsUnreadCount() {
    LineTestFactory.ensurePackageAccess();
    LINE_Conversation__c c = [
      SELECT Id, Unread_Count__c
      FROM LINE_Conversation__c
      WITH SYSTEM_MODE
    ];
    c.Unread_Count__c = 4;
    update as system c;

    Test.startTest();
    System.runAs(repA()) {
      Assert.areEqual(0, LineChatController.markRead(c.Id));
    }
    Test.stopTest();

    Assert.areEqual(
      0,
      [SELECT Unread_Count__c FROM LINE_Conversation__c WITH SYSTEM_MODE]
      .Unread_Count__c
    );
  }

  @IsTest
  static void markReadOnAnotherRepConversationIsRefused() {
    LineTestFactory.ensurePackageAccess();
    Id conversationId = conversationId();
    System.runAs(repB()) {
      try {
        LineChatController.markRead(conversationId);
        Assert.fail('Expected AuraHandledException');
      } catch (AuraHandledException e) {
        Assert.areEqual(System.Label.LINE_Error_No_Access, e.getMessage());
      }
    }
    Assert.areEqual(
      0,
      [SELECT Unread_Count__c FROM LINE_Conversation__c WITH SYSTEM_MODE]
      .Unread_Count__c
    );
  }

  @IsTest
  static void pollIntervalComesFromSettings() {
    LineTestFactory.ensurePackageAccess();
    System.runAs(repA()) {
      Assert.areEqual(2, LineChatController.getPollIntervalSeconds());
    }
    insert as system new LINE_Settings__c(
      SetupOwnerId = UserInfo.getOrganizationId(),
      Poll_Interval_Seconds__c = 9
    );
    LineSettings.reset();
    System.runAs(repA()) {
      Assert.areEqual(9, LineChatController.getPollIntervalSeconds());
    }
  }

  @IsTest
  static void ownerCanSendAndGetsMessageBack() {
    LineTestFactory.ensurePackageAccess();
    Test.setMock(HttpCalloutMock.class, new LineHttpMock());
    Id conversationId = conversationId();

    Test.startTest();
    LineChatController.MessageView view;
    System.runAs(repA()) {
      view = LineChatController.sendText(
        conversationId,
        'Hello from Salesforce'
      );
    }
    Test.stopTest();

    Assert.areEqual('Outbound', view.direction);
    Assert.areEqual('text', view.messageType);
    Assert.areEqual('Hello from Salesforce', view.text);
    Assert.areEqual('Sent', view.status);
    Assert.areEqual(repA().Id, view.senderId);
    Assert.isNotNull(view.id);
    Assert.isNull(view.errorMessage);
    Assert.areEqual(1, [SELECT COUNT() FROM LINE_Message__c WITH SYSTEM_MODE]);
  }

  @IsTest
  static void otherRepCannotSend() {
    LineTestFactory.ensurePackageAccess();
    Test.setMock(HttpCalloutMock.class, new LineHttpMock());
    Id conversationId = conversationId();

    Test.startTest();
    System.runAs(repB()) {
      try {
        LineChatController.sendText(conversationId, 'not my conversation');
        Assert.fail('Expected AuraHandledException');
      } catch (AuraHandledException e) {
        Assert.areEqual(System.Label.LINE_Error_No_Access, e.getMessage());
      }
    }
    Test.stopTest();

    Assert.areEqual(
      0,
      [SELECT COUNT() FROM LINE_Message__c WITH SYSTEM_MODE],
      'Nothing sent or stored'
    );
  }

  // ---------- who may send (DEC-37, TA review R1) ----------

  // Lets another user see the conversation, as a manager with View All or a sharing rule would.
  private static void shareWith(Id conversationId, Id userId) {
    insert as system new LINE_Conversation__Share(
      ParentId = conversationId,
      UserOrGroupId = userId,
      AccessLevel = 'Read'
    );
  }

  private static void setOaActive(Boolean active) {
    LINE_OA_Configuration__c oa = [
      SELECT Id
      FROM LINE_OA_Configuration__c
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    oa.Is_Active__c = active;
    update as system oa;
  }

  private static void setFallbackOwner(Id ownerId) {
    upsert as system new LINE_Settings__c(
      SetupOwnerId = UserInfo.getOrganizationId(),
      Fallback_Owner_Id__c = ownerId
    );
    LineSettings.reset();
  }

  @IsTest
  static void seeingAConversationIsNotEnoughToSend() {
    LineTestFactory.ensurePackageAccess();
    LineHttpMock mock = new LineHttpMock();
    Test.setMock(HttpCalloutMock.class, mock);
    Contact contact = linkContact(true);
    Id conversationId = conversationId();
    User other = repB();
    shareWith(conversationId, other.Id);

    List<LineChatController.ConversationView> views;
    String message;
    Test.startTest();
    System.runAs(other) {
      views = LineChatController.getConversations(contact.Id);
      try {
        LineChatController.sendText(conversationId, 'sent as someone else');
      } catch (AuraHandledException e) {
        message = e.getMessage();
      }
    }
    Test.stopTest();

    Assert.areEqual(1, views.size(), 'The shared conversation is readable');
    Assert.isFalse(views[0].canSend, 'The panel shows it read-only');
    Assert.areEqual(System.Label.LINE_Chat_Not_Assigned_Rep, message);
    Assert.areEqual(0, mock.requests.size(), 'No callout to LINE');
    Assert.areEqual(0, [SELECT COUNT() FROM LINE_Message__c WITH SYSTEM_MODE]);
  }

  @IsTest
  static void assignedRepCanSend() {
    LineTestFactory.ensurePackageAccess();
    Contact contact = linkContact(true);

    List<LineChatController.ConversationView> views;
    System.runAs(repA()) {
      views = LineChatController.getConversations(contact.Id);
    }

    Assert.isTrue(views[0].canSend);
  }

  @IsTest
  static void fallbackOwnerCanSendForAnInactiveOa() {
    LineTestFactory.ensurePackageAccess();
    Test.setMock(HttpCalloutMock.class, new LineHttpMock());
    Id conversationId = conversationId();
    User fallback = repB();
    setOaActive(false);
    setFallbackOwner(fallback.Id);
    shareWith(conversationId, fallback.Id);

    LineChatController.MessageView sent;
    String assignedRepError;
    Test.startTest();
    System.runAs(fallback) {
      sent = LineChatController.sendText(
        conversationId,
        'covering for my colleague'
      );
    }
    System.runAs(repA()) {
      try {
        LineChatController.sendText(conversationId, 'I was moved off this OA');
      } catch (AuraHandledException e) {
        assignedRepError = e.getMessage();
      }
    }
    Test.stopTest();

    Assert.areEqual('Sent', sent.status);
    Assert.areEqual(
      System.Label.LINE_Chat_Not_Assigned_Rep,
      assignedRepError,
      'Once the OA is inactive its conversations belong to the fallback owner'
    );
  }

  @IsTest
  static void fallbackQueueMemberCanSendForAnInactiveOa() {
    LineTestFactory.ensurePackageAccess();
    Test.setMock(HttpCalloutMock.class, new LineHttpMock());
    Id conversationId = conversationId();
    User member = repB();
    Group queue = new Group(Name = 'LINE fallback test', Type = 'Queue');
    // Setup objects in their own context, away from the non-setup DML of this test.
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insert as system queue;
      insert as system new GroupMember(
        GroupId = queue.Id,
        UserOrGroupId = member.Id
      );
    }
    setOaActive(false);
    setFallbackOwner(queue.Id);
    shareWith(conversationId, member.Id);

    LineChatController.MessageView sent;
    Test.startTest();
    System.runAs(member) {
      sent = LineChatController.sendText(conversationId, 'from the queue');
    }
    Test.stopTest();

    Assert.areEqual('Sent', sent.status);
  }

  @IsTest
  static void nullConversationIsRefused() {
    LineTestFactory.ensurePackageAccess();
    System.runAs(repA()) {
      try {
        LineChatController.sendText(null, 'nowhere');
        Assert.fail('Expected AuraHandledException');
      } catch (AuraHandledException e) {
        Assert.areEqual(System.Label.LINE_Error_No_Access, e.getMessage());
      }
    }
  }

  @IsTest
  static void unfollowedConversationIsRefusedBeforeSending() {
    LineTestFactory.ensurePackageAccess();
    LineHttpMock mock = new LineHttpMock();
    Test.setMock(HttpCalloutMock.class, mock);
    LINE_Conversation__c c = [
      SELECT Id, Status__c
      FROM LINE_Conversation__c
      WITH SYSTEM_MODE
    ];
    c.Status__c = 'Unfollowed';
    update as system c;

    System.runAs(repA()) {
      try {
        LineChatController.sendText(c.Id, 'are you there?');
        Assert.fail('Expected AuraHandledException');
      } catch (AuraHandledException e) {
        Assert.areEqual(
          System.Label.LINE_Error_Conversation_Inactive,
          e.getMessage()
        );
      }
    }
    Assert.areEqual(0, mock.requests.size(), 'No callout to LINE');
  }

  @IsTest
  static void invalidTextIsRefusedWithLabel() {
    LineTestFactory.ensurePackageAccess();
    Test.setMock(HttpCalloutMock.class, new LineHttpMock());
    Id conversationId = conversationId();

    System.runAs(repA()) {
      try {
        LineChatController.sendText(conversationId, '  ');
        Assert.fail('Expected AuraHandledException');
      } catch (AuraHandledException e) {
        Assert.areEqual(System.Label.LINE_Error_Message_Empty, e.getMessage());
      }
    }
  }

  @IsTest
  static void lineErrorReachesTheRepReadably() {
    LineTestFactory.ensurePackageAccess();
    LineHttpMock mock = new LineHttpMock();
    mock.stub(
      'POST',
      '/v2/bot/message/push',
      429,
      '{"message":"You have reached your monthly limit."}'
    );
    Test.setMock(HttpCalloutMock.class, mock);
    Id conversationId = conversationId();

    Test.startTest();
    System.runAs(repA()) {
      try {
        LineChatController.sendText(conversationId, 'over quota');
        Assert.fail('Expected AuraHandledException');
      } catch (AuraHandledException e) {
        Assert.areEqual(System.Label.LINE_Error_Monthly_Limit, e.getMessage());
      }
    }
    Test.stopTest();

    Assert.areEqual(
      'Failed',
      [SELECT Status__c FROM LINE_Message__c WITH SYSTEM_MODE].Status__c,
      'The failed attempt is visible to the rep'
    );
  }

  @IsTest
  static void viewCarriesNoSecrets() {
    LineTestFactory.ensurePackageAccess();
    Test.setMock(HttpCalloutMock.class, new LineHttpMock());
    Id conversationId = conversationId();

    Test.startTest();
    LineChatController.MessageView view;
    System.runAs(repA()) {
      view = LineChatController.sendText(conversationId, 'hello');
    }
    Test.stopTest();

    String serialized = JSON.serialize(view);
    Assert.isFalse(serialized.contains(LineTestFactory.SECRET_A));
    Assert.isFalse(serialized.contains(LineHttpMock.FAKE_TOKEN));
    Assert.isFalse(serialized.contains(LineTestFactory.CHANNEL_A));
  }

  // ---------- inbox (M6) ----------

  private static LINE_Conversation__c inboxConversation(
    String lineUserId,
    Id ownerId,
    Decimal unread,
    Id contactId,
    Datetime lastMessageAt
  ) {
    LINE_OA_Configuration__c oa = [
      SELECT Id
      FROM LINE_OA_Configuration__c
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    return new LINE_Conversation__c(
      Name = lineUserId,
      LINE_OA_Configuration__c = oa.Id,
      LINE_User_Id__c = lineUserId,
      Unique_Key__c = LineTestFactory.CHANNEL_A + ':' + lineUserId,
      Status__c = 'Following',
      OwnerId = ownerId,
      Unread_Count__c = unread,
      Contact__c = contactId,
      Last_Message_At__c = lastMessageAt,
      Last_Message_Preview__c = 'hi from ' + lineUserId
    );
  }

  private static Set<Id> idsOf(LineChatController.InboxPage page) {
    Set<Id> ids = new Set<Id>();
    for (LineChatController.ConversationView v : page.conversations) {
      ids.add(v.id);
    }
    return ids;
  }

  @IsTest
  static void inboxFiltersTheRepsOwnConversations() {
    LineTestFactory.ensurePackageAccess();
    User rep = repA();
    Contact contact = new Contact(LastName = 'Linked', OwnerId = rep.Id);
    insert as system contact;
    Datetime now = Datetime.now();
    LINE_Conversation__c unreadLinked = inboxConversation(
      'Uib1',
      rep.Id,
      2,
      contact.Id,
      now
    );
    LINE_Conversation__c readUnlinked = inboxConversation(
      'Uib2',
      rep.Id,
      0,
      null,
      now.addMinutes(-1)
    );
    LINE_Conversation__c someoneElses = inboxConversation(
      'Uib3',
      repB().Id,
      5,
      null,
      now
    );
    insert as system new List<LINE_Conversation__c>{
      unreadLinked,
      readUnlinked,
      someoneElses
    };

    LineChatController.InboxPage unread;
    LineChatController.InboxPage unlinked;
    LineChatController.InboxPage all;
    Test.startTest();
    System.runAs(rep) {
      unread = LineChatController.getInbox('unread', null, null);
      unlinked = LineChatController.getInbox('unlinked', null, null);
      all = LineChatController.getInbox('all', null, null);
    }
    Test.stopTest();

    Assert.areEqual(new Set<Id>{ unreadLinked.Id }, idsOf(unread));
    Assert.areEqual(new Set<Id>{ readUnlinked.Id }, idsOf(unlinked));
    Assert.areEqual(
      new Set<Id>{ unreadLinked.Id, readUnlinked.Id },
      idsOf(all),
      'Another rep\'s conversation never shows, and one with no message yet is left out'
    );
    Assert.areEqual(
      unreadLinked.Id,
      all.conversations[0].id,
      'Most recent first'
    );
    LineChatController.ConversationView first = all.conversations[0];
    Assert.areEqual(contact.Id, first.contactId);
    Assert.areEqual('Linked', first.contactName);
    Assert.areEqual('hi from Uib1', first.lastMessagePreview);
    Assert.isTrue(first.canSend, 'Rep A is the OA\'s assigned rep');
    Assert.isFalse(all.isAdmin);
  }

  @IsTest
  static void inboxPagesWithoutOffset() {
    LineTestFactory.ensurePackageAccess();
    User rep = repA();
    List<LINE_Conversation__c> many = new List<LINE_Conversation__c>();
    Datetime base = Datetime.now();
    Integer total = LineChatController.INBOX_PAGE_SIZE + 3;
    for (Integer i = 0; i < total; i++) {
      many.add(
        inboxConversation('Upage' + i, rep.Id, 0, null, base.addMinutes(-i))
      );
    }
    insert as system many;

    LineChatController.InboxPage first;
    LineChatController.InboxPage second;
    Test.startTest();
    System.runAs(rep) {
      first = LineChatController.getInbox('all', null, null);
      LineChatController.ConversationView last = first.conversations[
        first.conversations.size() - 1
      ];
      second = LineChatController.getInbox('all', last.lastMessageAt, last.id);
    }
    Test.stopTest();

    Assert.areEqual(
      LineChatController.INBOX_PAGE_SIZE,
      first.conversations.size()
    );
    Assert.isTrue(first.hasMore);
    Assert.areEqual(3, second.conversations.size());
    Assert.isFalse(second.hasMore);
    Set<Id> overlap = idsOf(first);
    overlap.retainAll(idsOf(second));
    Assert.isTrue(overlap.isEmpty(), 'No row appears on two pages');
  }

  @IsTest
  static void getConversationIsRefusedForAConversationTheUserCannotSee() {
    LineTestFactory.ensurePackageAccess();
    Id conversationId = conversationId();
    String message;
    System.runAs(repB()) {
      try {
        LineChatController.getConversation(conversationId);
      } catch (AuraHandledException e) {
        message = e.getMessage();
      }
    }
    Assert.areEqual(System.Label.LINE_Error_No_Access, message);
  }

  // ---------- linking (03 §5 rule 3) ----------

  @IsTest
  static void repLinksTheirConversationToTheirContact() {
    LineTestFactory.ensurePackageAccess();
    User rep = repA();
    Contact contact = new Contact(LastName = 'Real Somchai', OwnerId = rep.Id);
    insert as system contact;
    Id conversationId = conversationId();

    LineChatController.LinkView view;
    Test.startTest();
    System.runAs(rep) {
      view = LineChatController.linkToContact(conversationId, contact.Id);
    }
    Test.stopTest();

    Assert.areEqual(contact.Id, view.conversation.contactId);
    Assert.areEqual('Real Somchai', view.conversation.contactName);
    Assert.isFalse(view.placeholderDeleted);
    Assert.isFalse(view.placeholderKept);
  }

  @IsTest
  static void linkNeedsAContactToEdit() {
    LineTestFactory.ensurePackageAccess();
    Id conversationId = conversationId();
    String message;
    System.runAs(repA()) {
      try {
        // Not a Contact Id at all.
        LineChatController.linkToContact(conversationId, conversationId);
      } catch (AuraHandledException e) {
        message = e.getMessage();
      }
    }
    Assert.areEqual(System.Label.LINE_Link_No_Edit, message);
    Assert.isNull(
      [
        SELECT Contact__c
        FROM LINE_Conversation__c
        WHERE Id = :conversationId
        WITH SYSTEM_MODE
      ]
      .Contact__c
    );
  }

  @IsTest
  static void linkRefusalNamesTheHolderTheRepCanSee() {
    LineTestFactory.ensurePackageAccess();
    User rep = repA();
    Contact holder = new Contact(
      LastName = 'Existing Somchai',
      OwnerId = rep.Id,
      LINE_User_Id__c = 'Ucustomer1'
    );
    Contact chosen = new Contact(LastName = 'Chosen', OwnerId = rep.Id);
    insert as system new List<Contact>{ holder, chosen };
    Id conversationId = conversationId();

    String message;
    System.runAs(rep) {
      try {
        LineChatController.linkToContact(conversationId, chosen.Id);
      } catch (AuraHandledException e) {
        message = e.getMessage();
      }
    }
    Assert.areEqual(
      String.format(
        System.Label.LINE_Link_Held_By,
        new List<Object>{ 'Existing Somchai' }
      ),
      message
    );
  }

  @IsTest
  static void onlyAdminsCanUnlink() {
    LineTestFactory.ensurePackageAccess();
    User rep = repA();
    Contact contact = new Contact(LastName = 'Linked', OwnerId = rep.Id);
    insert as system contact;
    LINE_Conversation__c c = [
      SELECT Id
      FROM LINE_Conversation__c
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    c.Contact__c = contact.Id;
    update as system c;

    String message;
    System.runAs(rep) {
      try {
        LineChatController.unlinkConversation(c.Id);
      } catch (AuraHandledException e) {
        message = e.getMessage();
      }
    }
    Assert.areEqual(System.Label.LINE_Error_Admin_Only, message);
    Assert.areEqual(
      contact.Id,
      [
        SELECT Contact__c
        FROM LINE_Conversation__c
        WHERE Id = :c.Id
        WITH SYSTEM_MODE
      ]
      .Contact__c
    );
  }

  // ---------- QR invite (03 §5 rule 5) ----------

  @IsTest
  static void createInviteSavesACodeAndBuildsTheRepsOaLink() {
    LineTestFactory.ensurePackageAccess();
    User rep = repA();
    Contact contact = new Contact(LastName = 'To invite', OwnerId = rep.Id);
    insert as system contact;
    LINE_OA_Configuration__c oa = [
      SELECT Basic_Id__c, Name
      FROM LINE_OA_Configuration__c
      WITH SYSTEM_MODE
      LIMIT 1
    ];

    LineChatController.InviteView invite;
    Test.startTest();
    System.runAs(rep) {
      invite = LineChatController.createInvite(contact.Id);
    }
    Test.stopTest();

    Contact saved = [
      SELECT LINE_Invite_Code__c, LINE_Invite_Expires_At__c
      FROM Contact
      WHERE Id = :contact.Id
      WITH SYSTEM_MODE
    ];
    Assert.areEqual(saved.LINE_Invite_Code__c, invite.code);
    Assert.isTrue(
      invite.url.startsWith(
        'https://line.me/R/oaMessage/' +
          EncodingUtil.urlEncode(oa.Basic_Id__c, 'UTF-8') +
          '/?'
      )
    );
    Assert.isTrue(
      invite.url.endsWith('%23' + invite.code),
      'The code travels in the pre-filled text'
    );
    Assert.areEqual(oa.Name, invite.oaName);
    Assert.isTrue(
      saved.LINE_Invite_Expires_At__c > Datetime.now().addDays(6),
      'Seven days by default'
    );
  }

  @IsTest
  static void createInviteNeedsAnActiveOaOfYourOwn() {
    LineTestFactory.ensurePackageAccess();
    User other = repB();
    Contact contact = new Contact(LastName = 'To invite', OwnerId = other.Id);
    insert as system contact;

    String message;
    System.runAs(other) {
      try {
        LineChatController.createInvite(contact.Id);
      } catch (AuraHandledException e) {
        message = e.getMessage();
      }
    }
    Assert.areEqual(System.Label.LINE_Invite_No_OA, message);
  }

  // ---------- files (M7) ----------

  @IsTest
  static void messagesCarryTheirFilesLatestVersionForTheThumbnail() {
    LineTestFactory.ensurePackageAccess();
    Id conversationId = conversationId();
    ContentVersion v = new ContentVersion(
      Title = 'photo',
      PathOnClient = 'photo.jpg',
      VersionData = Blob.valueOf('fake-binary'),
      FirstPublishLocationId = conversationId
    );
    insert as system v;
    Id documentId = [
      SELECT ContentDocumentId
      FROM ContentVersion
      WHERE Id = :v.Id
      WITH SYSTEM_MODE
    ]
    .ContentDocumentId;
    insert as system new LINE_Message__c(
      LINE_Conversation__c = conversationId,
      Direction__c = 'Inbound',
      Message_Type__c = 'image',
      Status__c = 'Received',
      Sent_At__c = Datetime.now(),
      Webhook_Event_Id__c = 'evt-photo',
      Content_Document_Id__c = documentId
    );

    LineChatController.MessagePage page;
    System.runAs(repA()) {
      page = LineChatController.getMessages(conversationId, null, null, null);
    }

    Assert.areEqual(String.valueOf(v.Id), page.messages[0].contentVersionId);
  }
}
