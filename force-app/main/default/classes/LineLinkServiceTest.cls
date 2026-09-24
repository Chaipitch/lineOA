@IsTest
private class LineLinkServiceTest {
  private static final String USER_1 = 'Ucustomer1';
  private static final String USER_2 = 'Ucustomer2';

  @TestSetup
  static void setup() {
    LineTestFactory.ensurePackageAccess();
    LINE_OA_Configuration__c oa = LineTestFactory.createOA(
      LineTestFactory.CHANNEL_A,
      LineTestFactory.BOT_A,
      LineTestFactory.SECRET_A,
      UserInfo.getUserId()
    );
    insert as system new List<LINE_Conversation__c>{
      conversation(oa.Id, USER_1),
      conversation(oa.Id, USER_2)
    };
  }

  private static LINE_Conversation__c conversation(Id oaId, String lineUserId) {
    return new LINE_Conversation__c(
      Name = lineUserId,
      LINE_OA_Configuration__c = oaId,
      LINE_User_Id__c = lineUserId,
      Unique_Key__c = LineTestFactory.CHANNEL_A + ':' + lineUserId,
      OwnerId = UserInfo.getUserId()
    );
  }

  // By unique key, not by LINE user ID: the same customer can have one conversation per OA.
  private static LINE_Conversation__c conversationFor(String lineUserId) {
    String key = LineTestFactory.CHANNEL_A + ':' + lineUserId;
    return [
      SELECT Id, Contact__c, LINE_OA_Configuration__c
      FROM LINE_Conversation__c
      WHERE Unique_Key__c = :key
      WITH SYSTEM_MODE
    ];
  }

  private static void setAutoCreate(Boolean value) {
    LINE_Settings__c settings = new LINE_Settings__c(
      SetupOwnerId = UserInfo.getOrganizationId(),
      Auto_Create_Contact__c = value
    );
    upsert as system settings;
    LineSettings.reset();
  }

  @IsTest
  static void createsContactNamedAfterTheLineDisplayName() {
    LineTestFactory.ensurePackageAccess();
    setAutoCreate(true);
    Id conversationId = conversationFor(USER_1).Id;

    Test.startTest();
    Map<Id, Id> result = LineLinkService.resolveContacts(
      new Set<Id>{ conversationId },
      new Map<Id, String>{ conversationId => 'สมชาย' }
    );
    Test.stopTest();

    Assert.areEqual(1, result.size(), 'The conversation should gain a Contact');
    Contact created = [
      SELECT LastName, LINE_User_Id__c, LINE_OA_Configuration__c, OwnerId
      FROM Contact
      WHERE Id = :result.get(conversationId)
      WITH SYSTEM_MODE
    ];
    Assert.areEqual('สมชาย', created.LastName);
    Assert.areEqual(USER_1, created.LINE_User_Id__c);
    Assert.areEqual(
      conversationFor(USER_1).LINE_OA_Configuration__c,
      created.LINE_OA_Configuration__c,
      'The Contact records which OA it came from'
    );
    Assert.areEqual(
      UserInfo.getUserId(),
      created.OwnerId,
      'The rep who owns the conversation owns the Contact'
    );
  }

  @IsTest
  static void linksToAnExistingContactInsteadOfCreatingOne() {
    LineTestFactory.ensurePackageAccess();
    setAutoCreate(true);
    Contact existing = new Contact(
      LastName = 'Already Known',
      LINE_User_Id__c = USER_1
    );
    insert as system existing;
    Id conversationId = conversationFor(USER_1).Id;

    Test.startTest();
    Map<Id, Id> result = LineLinkService.resolveContacts(
      new Set<Id>{ conversationId },
      new Map<Id, String>{ conversationId => 'Whatever LINE says' }
    );
    Test.stopTest();

    Assert.areEqual(existing.Id, result.get(conversationId));
    Assert.areEqual(
      1,
      [SELECT COUNT() FROM Contact WHERE LINE_User_Id__c = :USER_1],
      'No second Contact for a LINE user that already has one'
    );
  }

  @IsTest
  static void createsNothingWhenAutoCreateIsOff() {
    LineTestFactory.ensurePackageAccess();
    setAutoCreate(false);
    Id conversationId = conversationFor(USER_1).Id;

    Test.startTest();
    Map<Id, Id> result = LineLinkService.resolveContacts(
      new Set<Id>{ conversationId },
      new Map<Id, String>()
    );
    Test.stopTest();

    Assert.isTrue(
      result.isEmpty(),
      'The setting is off, so nothing is created'
    );
    Assert.areEqual(0, [SELECT COUNT() FROM Contact]);
  }

  @IsTest
  static void skipsConversationsThatAlreadyHaveAContact() {
    LineTestFactory.ensurePackageAccess();
    setAutoCreate(true);
    Contact linked = new Contact(LastName = 'Linked by the rep');
    insert as system linked;
    LINE_Conversation__c c = conversationFor(USER_1);
    c.Contact__c = linked.Id;
    update as system c;

    Test.startTest();
    Map<Id, Id> result = LineLinkService.resolveContacts(
      new Set<Id>{ c.Id },
      new Map<Id, String>()
    );
    Test.stopTest();

    Assert.isTrue(result.isEmpty());
    Assert.areEqual(1, [SELECT COUNT() FROM Contact]);
  }

  @IsTest
  static void fallsBackToTheConversationNameWhenTheProfileIsUnknown() {
    LineTestFactory.ensurePackageAccess();
    setAutoCreate(true);
    Id conversationId = conversationFor(USER_1).Id;

    Test.startTest();
    Map<Id, Id> result = LineLinkService.resolveContacts(
      new Set<Id>{ conversationId },
      new Map<Id, String>()
    );
    Test.stopTest();

    Assert.areEqual(
      USER_1,
      [
        SELECT LastName
        FROM Contact
        WHERE Id = :result.get(conversationId)
        WITH SYSTEM_MODE
      ]
      .LastName,
      'With no display name the LINE user ID is the only name we have'
    );
  }

  @IsTest
  static void createsOneContactPerLineUserAcrossConversations() {
    LineTestFactory.ensurePackageAccess();
    setAutoCreate(true);
    // A second OA chatting with the same customer: one person, one Contact, two conversations.
    LINE_OA_Configuration__c second = LineTestFactory.createOA(
      LineTestFactory.CHANNEL_B,
      LineTestFactory.BOT_B,
      LineTestFactory.SECRET_B,
      UserInfo.getUserId()
    );
    LINE_Conversation__c other = new LINE_Conversation__c(
      Name = USER_1,
      LINE_OA_Configuration__c = second.Id,
      LINE_User_Id__c = USER_1,
      Unique_Key__c = LineTestFactory.CHANNEL_B + ':' + USER_1,
      OwnerId = UserInfo.getUserId()
    );
    insert as system other;

    Test.startTest();
    Map<Id, Id> result = LineLinkService.resolveContacts(
      new Set<Id>{ conversationFor(USER_1).Id, other.Id },
      new Map<Id, String>()
    );
    Test.stopTest();

    Assert.areEqual(2, result.size());
    Assert.areEqual(
      1,
      [SELECT COUNT() FROM Contact],
      'Both conversations share one Contact'
    );
    Assert.areEqual(
      result.values()[0],
      result.values()[1],
      'Both point at the same Contact'
    );
  }

  @IsTest
  static void longDisplayNameIsTruncatedToFit() {
    LineTestFactory.ensurePackageAccess();
    setAutoCreate(true);
    Id conversationId = conversationFor(USER_1).Id;

    Test.startTest();
    Map<Id, Id> result = LineLinkService.resolveContacts(
      new Set<Id>{ conversationId },
      new Map<Id, String>{ conversationId => 'x'.repeat(200) }
    );
    Test.stopTest();

    Assert.areEqual(1, result.size());
    Assert.areEqual(
      80,
      [
          SELECT LastName
          FROM Contact
          WHERE Id = :result.get(conversationId)
          WITH SYSTEM_MODE
        ]
        .LastName.length(),
      'A LINE display name longer than the field is cut, not rejected'
    );
  }

  @IsTest
  static void contactDmlFailureIsLoggedAndLeavesTheConversationUnlinked() {
    LineTestFactory.ensurePackageAccess();
    setAutoCreate(true);
    User rep = LineTestFactory.createUser(new List<String>{ 'LINE_Chat_User' });
    LINE_Conversation__c c = conversationFor(USER_1);
    c.OwnerId = rep.Id;
    update as system c;
    // Standing in for any subscriber-side rejection (validation rule, trigger, required field): Salesforce
    // refuses a Contact owned by an inactive user.
    System.runAs(new User(Id = UserInfo.getUserId())) {
      rep.IsActive = false;
      update as system rep;
    }

    Test.startTest();
    Map<Id, Id> result = LineLinkService.resolveContacts(
      new Set<Id>{ c.Id },
      new Map<Id, String>{ c.Id => 'Somchai' }
    );
    // The buffered logger is flushed by the entry point; here the test is the entry point.
    LineLogger.flush();
    Test.stopTest();

    Assert.isTrue(result.isEmpty(), 'Nothing is linked when the insert fails');
    Assert.areEqual(0, [SELECT COUNT() FROM Contact]);
    Assert.areEqual(
      'LineLinkService.createContacts',
      [SELECT Source__c FROM LINE_Error_Log__c WITH SYSTEM_MODE].Source__c,
      'The failure is logged rather than thrown'
    );
  }

  @IsTest
  static void emptyInputDoesNothing() {
    LineTestFactory.ensurePackageAccess();
    Test.startTest();
    Assert.isTrue(
      LineLinkService.resolveContacts(new Set<Id>(), null).isEmpty()
    );
    Assert.isTrue(LineLinkService.resolveContacts(null, null).isEmpty());
    Test.stopTest();
    Assert.areEqual(0, [SELECT COUNT() FROM Contact]);
  }
}
