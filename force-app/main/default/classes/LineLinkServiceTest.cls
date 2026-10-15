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

  private static void setDefaultAccount(Id accountId) {
    LINE_Settings__c settings = new LINE_Settings__c(
      SetupOwnerId = UserInfo.getOrganizationId(),
      Auto_Create_Contact__c = true,
      Default_Account_Id__c = accountId
    );
    upsert as system settings;
    LineSettings.reset();
  }

  @IsTest
  static void createsContactUnderTheDefaultAccount() {
    LineTestFactory.ensurePackageAccess();
    Account placeholder = new Account(Name = 'LINE Unassigned');
    insert as system placeholder;
    setDefaultAccount(placeholder.Id);
    Id conversationId = conversationFor(USER_1).Id;

    Test.startTest();
    Map<Id, Id> result = LineLinkService.resolveContacts(
      new Set<Id>{ conversationId },
      new Map<Id, String>{ conversationId => 'Somchai' }
    );
    Test.stopTest();

    Contact created = [
      SELECT AccountId
      FROM Contact
      WHERE Id = :result.get(conversationId)
      WITH SYSTEM_MODE
    ];
    Assert.areEqual(
      placeholder.Id,
      created.AccountId,
      'With an Account the Contact is shared like the Account, not private to its owner (DEC-36)'
    );
  }

  @IsTest
  static void deletedDefaultAccountIsLoggedAndContactCreatedWithoutOne() {
    LineTestFactory.ensurePackageAccess();
    Account placeholder = new Account(Name = 'LINE Unassigned');
    insert as system placeholder;
    setDefaultAccount(placeholder.Id);
    delete as system placeholder;
    Id conversationId = conversationFor(USER_1).Id;

    Test.startTest();
    Map<Id, Id> result = LineLinkService.resolveContacts(
      new Set<Id>{ conversationId },
      new Map<Id, String>{ conversationId => 'Somchai' }
    );
    LineLogger.flush();
    Test.stopTest();

    Assert.isNull(
      [
        SELECT AccountId
        FROM Contact
        WHERE Id = :result.get(conversationId)
        WITH SYSTEM_MODE
      ]
      .AccountId,
      'A missing default Account must not stop the Contact being created'
    );
    Assert.areEqual(
      1,
      [
        SELECT COUNT()
        FROM LINE_Error_Log__c
        WHERE Source__c = 'LineLinkService.createContacts'
        WITH SYSTEM_MODE
      ],
      'The admin is told the setting points at a deleted Account'
    );
  }

  @IsTest
  static void linkingNeverMovesAnExistingContactToTheDefaultAccount() {
    LineTestFactory.ensurePackageAccess();
    Account placeholder = new Account(Name = 'LINE Unassigned');
    insert as system placeholder;
    setDefaultAccount(placeholder.Id);
    Contact existing = new Contact(
      LastName = 'Existing',
      LINE_User_Id__c = USER_1
    );
    insert as system existing;
    Id conversationId = conversationFor(USER_1).Id;

    Test.startTest();
    LineLinkService.resolveContacts(new Set<Id>{ conversationId }, null);
    Test.stopTest();

    Assert.isNull(
      [SELECT AccountId FROM Contact WHERE Id = :existing.Id WITH SYSTEM_MODE]
      .AccountId,
      'Only Contacts we create get the default Account'
    );
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
      SELECT
        LastName,
        LINE_User_Id__c,
        LINE_OA_Configuration__c,
        OwnerId,
        LINE_Auto_Created__c
      FROM Contact
      WHERE Id = :result.get(conversationId)
      WITH SYSTEM_MODE
    ];
    Assert.areEqual('สมชาย', created.LastName);
    Assert.areEqual(USER_1, created.LINE_User_Id__c);
    Assert.isTrue(
      created.LINE_Auto_Created__c,
      'Marked as a placeholder, so a manual link can remove it (DEC-34)'
    );
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
      [
        SELECT COUNT()
        FROM Contact
        WHERE LINE_User_Id__c = :USER_1
        WITH SYSTEM_MODE
      ],
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
    Assert.areEqual(0, [SELECT COUNT() FROM Contact WITH SYSTEM_MODE]);
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
    Assert.areEqual(1, [SELECT COUNT() FROM Contact WITH SYSTEM_MODE]);
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
      [SELECT COUNT() FROM Contact WITH SYSTEM_MODE],
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
    Assert.areEqual(0, [SELECT COUNT() FROM Contact WITH SYSTEM_MODE]);
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
    Assert.areEqual(0, [SELECT COUNT() FROM Contact WITH SYSTEM_MODE]);
  }

  // ---------- manual link (03 §5 rule 3, DEC-34) ----------

  private static Contact placeholderFor(String lineUserId) {
    Contact placeholder = new Contact(
      LastName = 'Auto ' + lineUserId,
      LINE_User_Id__c = lineUserId,
      LINE_Auto_Created__c = true
    );
    insert as system placeholder;
    LINE_Conversation__c c = conversationFor(lineUserId);
    c.Contact__c = placeholder.Id;
    update as system c;
    return placeholder;
  }

  @IsTest
  static void linkSetsTheLineUserIdAndPrimaryOaOnAContactWithout() {
    LineTestFactory.ensurePackageAccess();
    Contact real = new Contact(LastName = 'Real Somchai');
    insert as system real;
    LINE_Conversation__c c = conversationFor(USER_1);

    Test.startTest();
    LineLinkService.LinkResult result = LineLinkService.linkToContact(
      c.Id,
      real.Id
    );
    Test.stopTest();

    Contact after = [
      SELECT LINE_User_Id__c, LINE_OA_Configuration__c
      FROM Contact
      WHERE Id = :real.Id
      WITH SYSTEM_MODE
    ];
    Assert.areEqual(USER_1, after.LINE_User_Id__c);
    Assert.areEqual(c.LINE_OA_Configuration__c, after.LINE_OA_Configuration__c);
    Assert.areEqual(real.Id, conversationFor(USER_1).Contact__c);
    Assert.isFalse(result.placeholderDeleted);
    Assert.isNull(result.placeholderKeptId);
  }

  @IsTest
  static void linkRefusesAContactHoldingAnotherLineUser() {
    LineTestFactory.ensurePackageAccess();
    Contact other = new Contact(LastName = 'Other', LINE_User_Id__c = USER_2);
    insert as system other;

    Test.startTest();
    try {
      LineLinkService.linkToContact(conversationFor(USER_1).Id, other.Id);
      Assert.fail('Expected LinkException');
    } catch (LineLinkService.LinkException e) {
      Assert.areEqual(
        System.Label.LINE_Link_Contact_Has_Other_User,
        e.getMessage()
      );
    }
    Test.stopTest();

    Assert.isNull(conversationFor(USER_1).Contact__c, 'Nothing changed');
  }

  @IsTest
  static void linkRefusesWhenAPersonsContactHoldsTheLineUser() {
    LineTestFactory.ensurePackageAccess();
    Contact holder = new Contact(
      LastName = 'Linked by a rep',
      LINE_User_Id__c = USER_1
    );
    insert as system holder;
    Contact chosen = new Contact(LastName = 'Chosen');
    insert as system chosen;

    Test.startTest();
    try {
      LineLinkService.linkToContact(conversationFor(USER_1).Id, chosen.Id);
      Assert.fail('Expected LinkException');
    } catch (LineLinkService.LinkException e) {
      Assert.areEqual(holder.Id, e.holderId, 'The caller can name the holder');
    }
    Test.stopTest();

    Assert.areEqual(
      USER_1,
      [
        SELECT LINE_User_Id__c
        FROM Contact
        WHERE Id = :holder.Id
        WITH SYSTEM_MODE
      ]
      .LINE_User_Id__c,
      'A Contact a person linked is never taken over'
    );
  }

  @IsTest
  static void linkReplacesAnEmptyPlaceholderAndDeletesIt() {
    LineTestFactory.ensurePackageAccess();
    Contact placeholder = placeholderFor(USER_1);
    Account acme = new Account(Name = 'Acme');
    insert as system acme;
    Contact real = new Contact(LastName = 'Real', AccountId = acme.Id);
    insert as system real;
    LINE_Conversation__c c = conversationFor(USER_1);
    // A daily LINE Event already written on the placeholder moves with the customer.
    Event daily = new Event(
      Subject = 'LINE',
      WhoId = placeholder.Id,
      LINE_Conversation__c = c.Id,
      StartDateTime = Datetime.now(),
      EndDateTime = Datetime.now().addMinutes(5)
    );
    insert as system daily;

    Test.startTest();
    LineLinkService.LinkResult result = LineLinkService.linkToContact(
      c.Id,
      real.Id
    );
    Test.stopTest();

    Assert.isTrue(result.placeholderDeleted);
    Assert.areEqual(
      0,
      [SELECT COUNT() FROM Contact WHERE Id = :placeholder.Id WITH SYSTEM_MODE]
    );
    Assert.areEqual(real.Id, conversationFor(USER_1).Contact__c);
    Assert.areEqual(
      USER_1,
      [SELECT LINE_User_Id__c FROM Contact WHERE Id = :real.Id WITH SYSTEM_MODE]
      .LINE_User_Id__c
    );
    Event moved = [
      SELECT WhoId, WhatId
      FROM Event
      WHERE Id = :daily.Id
      WITH SYSTEM_MODE
    ];
    Assert.areEqual(real.Id, moved.WhoId);
    Assert.areEqual(
      acme.Id,
      moved.WhatId,
      'The Event follows the real Contact to its Account'
    );
  }

  @IsTest
  static void linkKeepsAPlaceholderThatHasOtherRecords() {
    LineTestFactory.ensurePackageAccess();
    Contact placeholder = placeholderFor(USER_1);
    insert as system new Task(Subject = 'Call back', WhoId = placeholder.Id);
    Contact real = new Contact(LastName = 'Real');
    insert as system real;

    Test.startTest();
    LineLinkService.LinkResult result = LineLinkService.linkToContact(
      conversationFor(USER_1).Id,
      real.Id
    );
    Test.stopTest();

    Assert.isFalse(result.placeholderDeleted);
    Assert.areEqual(
      placeholder.Id,
      result.placeholderKeptId,
      'Left for the rep to merge'
    );
    Contact kept = [
      SELECT LINE_User_Id__c
      FROM Contact
      WHERE Id = :placeholder.Id
      WITH SYSTEM_MODE
    ];
    Assert.isNull(
      kept.LINE_User_Id__c,
      'The LINE user ID moved to the chosen Contact'
    );
    Assert.areEqual(real.Id, conversationFor(USER_1).Contact__c);
  }

  @IsTest
  static void linkMovesTheCustomersOtherOaConversationsToo() {
    LineTestFactory.ensurePackageAccess();
    Contact placeholder = placeholderFor(USER_1);
    LINE_OA_Configuration__c oaB = LineTestFactory.createOA(
      LineTestFactory.CHANNEL_B,
      LineTestFactory.BOT_B,
      LineTestFactory.SECRET_B,
      UserInfo.getUserId()
    );
    LINE_Conversation__c onB = new LINE_Conversation__c(
      Name = USER_1,
      LINE_OA_Configuration__c = oaB.Id,
      LINE_User_Id__c = USER_1,
      Unique_Key__c = LineTestFactory.CHANNEL_B + ':' + USER_1,
      OwnerId = UserInfo.getUserId(),
      Contact__c = placeholder.Id
    );
    insert as system onB;
    Contact real = new Contact(LastName = 'Real');
    insert as system real;

    Test.startTest();
    LineLinkService.linkToContact(conversationFor(USER_1).Id, real.Id);
    Test.stopTest();

    Assert.areEqual(
      real.Id,
      [
        SELECT Contact__c
        FROM LINE_Conversation__c
        WHERE Id = :onB.Id
        WITH SYSTEM_MODE
      ]
      .Contact__c,
      'One customer, one Contact, across every OA'
    );
  }

  @IsTest
  static void aDeletedTargetChangesNothing() {
    LineTestFactory.ensurePackageAccess();
    Contact placeholder = placeholderFor(USER_1);
    Contact real = new Contact(LastName = 'Real');
    insert as system real;
    LINE_Conversation__c c = conversationFor(USER_1);

    Test.startTest();
    try {
      // The Contact was deleted between choosing it and pressing Link.
      delete as system real;
      LineLinkService.linkToContact(c.Id, real.Id);
      Assert.fail('Expected an exception');
    } catch (Exception e) {
      Assert.isNotNull(e.getMessage());
    }
    Test.stopTest();

    Assert.areEqual(
      USER_1,
      [
        SELECT LINE_User_Id__c
        FROM Contact
        WHERE Id = :placeholder.Id
        WITH SYSTEM_MODE
      ]
      .LINE_User_Id__c,
      'The placeholder keeps its LINE user ID'
    );
    Assert.areEqual(placeholder.Id, conversationFor(USER_1).Contact__c);
  }

  // ---------- unlink (03 §5 rule 4) ----------

  @IsTest
  static void unlinkClearsTheContactIdOnlyWhenNoConversationStillLinksIt() {
    LineTestFactory.ensurePackageAccess();
    Contact real = new Contact(LastName = 'Real', LINE_User_Id__c = USER_1);
    insert as system real;
    LINE_Conversation__c c = conversationFor(USER_1);
    c.Contact__c = real.Id;
    update as system c;

    Test.startTest();
    LineLinkService.unlink(c.Id);
    LineLinkService.unlink(c.Id);
    Test.stopTest();

    Assert.isNull(conversationFor(USER_1).Contact__c);
    Assert.isNull(
      [SELECT LINE_User_Id__c FROM Contact WHERE Id = :real.Id WITH SYSTEM_MODE]
      .LINE_User_Id__c,
      'No conversation links it any more, so auto-link cannot relink it'
    );
  }

  // ---------- invite codes (03 §5 rules 1 and 5) ----------

  @IsTest
  static void inviteCodeIsFoundAnywhereInTheText() {
    Assert.areEqual(
      'K7PM2QXA',
      LineLinkService.inviteCodeIn('Link my account #K7PM2QXA')
    );
    Assert.areEqual(
      'K7PM2QXA',
      LineLinkService.inviteCodeIn('hi #K7PM2QXA thanks!')
    );
    Assert.isNull(
      LineLinkService.inviteCodeIn('#k7pm2qxa'),
      'Codes are upper case'
    );
    Assert.isNull(
      LineLinkService.inviteCodeIn('#K7PM2QXAB'),
      'Nine characters is not a code'
    );
    Assert.isNull(
      LineLinkService.inviteCodeIn('#K7PM2QX0'),
      'No 0, 1, I or O in codes'
    );
    Assert.isNull(LineLinkService.inviteCodeIn(null));
  }

  @IsTest
  static void newInviteCodesUseTheUnambiguousAlphabet() {
    Set<String> seen = new Set<String>();
    for (Integer i = 0; i < 50; i++) {
      String code = LineLinkService.newInviteCode();
      Assert.areEqual(8, code.length());
      Assert.areEqual(
        code,
        LineLinkService.inviteCodeIn('#' + code),
        'Every code is matchable'
      );
      seen.add(code);
    }
    Assert.areEqual(50, seen.size(), 'Codes are random');
  }

  @IsTest
  static void linkByInviteClearsTheUsedCode() {
    LineTestFactory.ensurePackageAccess();
    Contact invited = new Contact(
      LastName = 'Invited',
      LINE_Invite_Code__c = 'K7PM2QXA',
      LINE_Invite_Expires_At__c = Datetime.now().addDays(1)
    );
    insert as system invited;

    Test.startTest();
    LineLinkService.linkByInvite(conversationFor(USER_1).Id, invited.Id);
    Test.stopTest();

    Contact after = [
      SELECT LINE_User_Id__c, LINE_Invite_Code__c, LINE_Invite_Expires_At__c
      FROM Contact
      WHERE Id = :invited.Id
      WITH SYSTEM_MODE
    ];
    Assert.areEqual(USER_1, after.LINE_User_Id__c);
    Assert.isNull(after.LINE_Invite_Code__c, 'One-time code');
    Assert.isNull(after.LINE_Invite_Expires_At__c);
    Assert.areEqual(invited.Id, conversationFor(USER_1).Contact__c);
  }

  // ---------- duplicate rules (DEC-48) ----------

  @IsTest
  static void contactWritesAcceptDuplicateAlerts() {
    Database.DMLOptions partial = LineLinkService.saveDespiteDuplicateAlerts(
      false
    );
    Assert.isTrue(
      partial.DuplicateRuleHeader.allowSave,
      'A duplicate rule that only warns must not stop the Contact'
    );
    Assert.isFalse(partial.OptAllOrNone, 'Auto-create stays partial-success');
    Assert.isTrue(
      LineLinkService.saveDespiteDuplicateAlerts(true).OptAllOrNone
    );
  }
}
