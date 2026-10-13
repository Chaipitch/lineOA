/**
 * Links conversations to Contacts (03 §5). This milestone implements rule 2 (auto-link by `LINE_User_Id__c`) and
 * the automatic creation of a Contact for a LINE user who has none. Invite codes (rule 1), manual link (rule 3)
 * and unlink (rule 4) follow in the rest of M6.
 *
 * Called from `LineCalloutQueueable` after the profile callout, so a new Contact carries the customer's LINE
 * display name rather than their opaque user ID. Contact DML is partial-success and never blocks message storage
 * (hard rule 7): a subscriber validation rule on Contact leaves the conversation unlinked and logged, nothing more.
 *
 * `without sharing` (02 §2): runs as Automated Process in the async follow-up of inbound processing, and creates
 * Contacts owned by the reps who own the conversations, which no user context could do.
 */
public without sharing class LineLinkService {
  private static final Integer LAST_NAME_LENGTH = 80;

  /** Invite code alphabet (03 §5): 32 characters, no I, O, 0 or 1, so a code can't be misread. */
  @TestVisible
  static final String INVITE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  @TestVisible
  static final Integer INVITE_CODE_LENGTH = 8;
  private static final Pattern INVITE_PATTERN = Pattern.compile(
    '#([A-HJ-NP-Z2-9]{8})(?![A-HJ-NP-Z2-9])'
  );

  /** A link the rules refuse (03 §5 rule 3). The message is a Custom Label, safe to show the rep. */
  public class LinkException extends Exception {
    /** The Contact already holding the LINE user ID, so the caller can name it if the user may see it. */
    public Id holderId;
  }

  /** What a manual link did. */
  public class LinkResult {
    public Id contactId;
    /** An auto-created placeholder Contact was deleted (DEC-34). */
    public Boolean placeholderDeleted = false;
    /** An auto-created placeholder was kept because other records are attached to it; the rep may merge it. */
    public Id placeholderKeptId;
  }

  /**
   * Links a conversation to a Contact the rep chose (03 §5 rule 3, DEC-34). Every conversation of the same LINE user
   * that is unlinked, or linked to the auto-created placeholder, moves to the chosen Contact too, so the customer
   * keeps one Contact across all OAs.
   *
   * The caller checks the user's access first (`LineChatController.linkToContact`: can read the conversation, has
   * Edit on the Contact). All writes are one unit: if any fails, nothing changes.
   *
   * @param conversationId the conversation to link
   * @param contactId the Contact the rep chose
   * @return what happened to any auto-created placeholder
   * @throws LinkException when the rules refuse the link
   */
  public static LinkResult linkToContact(Id conversationId, Id contactId) {
    return link(conversationId, contactId, false);
  }

  /**
   * Links through a QR invite (03 §5 rule 1): the same checks as a manual link, and the used code is cleared in the
   * same update. The caller has already checked that the code exists and is unexpired.
   *
   * @param conversationId the conversation the code arrived in
   * @param contactId the Contact the code was issued for
   * @return what happened to any auto-created placeholder
   * @throws LinkException when the rules refuse the link
   */
  public static LinkResult linkByInvite(Id conversationId, Id contactId) {
    return link(conversationId, contactId, true);
  }

  /**
   * A new random invite code (03 §5 rule 5). 32 symbols, so masking 5 bits of a random integer is unbiased.
   * @return 8 characters from `INVITE_ALPHABET`
   */
  public static String newInviteCode() {
    String code = '';
    for (Integer i = 0; i < INVITE_CODE_LENGTH; i++) {
      Integer index = Crypto.getRandomInteger() & 31;
      code += INVITE_ALPHABET.substring(index, index + 1);
    }
    return code;
  }

  /**
   * Finds an invite code (`#` + 8 characters) anywhere in a customer's message.
   * @param text the message text
   * @return the code without `#`, or null
   */
  public static String inviteCodeIn(String text) {
    if (String.isBlank(text)) {
      return null;
    }
    Matcher m = INVITE_PATTERN.matcher(text);
    return m.find() ? m.group(1) : null;
  }

  private static LinkResult link(
    Id conversationId,
    Id contactId,
    Boolean clearInvite
  ) {
    LINE_Conversation__c conversation = [
      SELECT Id, LINE_User_Id__c, LINE_OA_Configuration__c
      FROM LINE_Conversation__c
      WHERE Id = :conversationId
      WITH SYSTEM_MODE
    ];
    String lineUserId = conversation.LINE_User_Id__c;
    Contact target = [
      SELECT Id, AccountId, LINE_User_Id__c, LINE_OA_Configuration__c
      FROM Contact
      WHERE Id = :contactId
      WITH SYSTEM_MODE
    ];
    if (
      String.isNotBlank(target.LINE_User_Id__c) &&
      !target.LINE_User_Id__c.equals(lineUserId)
    ) {
      throw new LinkException(System.Label.LINE_Link_Contact_Has_Other_User);
    }

    Contact placeholder;
    for (Contact holder : [
      SELECT Id, LINE_Auto_Created__c
      FROM Contact
      WHERE LINE_User_Id__c = :lineUserId AND Id != :contactId
      WITH SYSTEM_MODE
      LIMIT 1
    ]) {
      if (!holder.LINE_Auto_Created__c) {
        // A Contact a person created or linked: never taken over silently.
        LinkException refused = new LinkException(
          System.Label.LINE_Link_Held_By_Hidden
        );
        refused.holderId = holder.Id;
        throw refused;
      }
      placeholder = holder;
    }

    LinkResult result = new LinkResult();
    result.contactId = target.Id;
    Savepoint savepoint = Database.setSavepoint();
    try {
      if (placeholder != null) {
        // LINE_User_Id__c is unique: free it before the chosen Contact takes it.
        update as system new Contact(
          Id = placeholder.Id,
          LINE_User_Id__c = null
        );
      }
      target.LINE_User_Id__c = lineUserId;
      if (clearInvite) {
        // One-time code (03 §5 rule 1).
        target.LINE_Invite_Code__c = null;
        target.LINE_Invite_Expires_At__c = null;
      }
      if (target.LINE_OA_Configuration__c == null) {
        target.LINE_OA_Configuration__c = conversation.LINE_OA_Configuration__c;
      }
      update as system target;

      Id placeholderId = placeholder?.Id;
      List<LINE_Conversation__c> moving = [
        SELECT Id
        FROM LINE_Conversation__c
        WHERE
          LINE_User_Id__c = :lineUserId
          AND (Id = :conversationId
          OR Contact__c = NULL
          OR Contact__c = :placeholderId)
        WITH SYSTEM_MODE
      ];
      for (LINE_Conversation__c c : moving) {
        c.Contact__c = target.Id;
      }
      update as system moving;

      if (placeholder != null) {
        // The daily LINE Events follow the customer; other activities stay and keep the placeholder alive.
        List<Event> lineEvents = [
          SELECT Id
          FROM Event
          WHERE WhoId = :placeholder.Id AND LINE_Conversation__c != NULL
          WITH SYSTEM_MODE
        ];
        for (Event e : lineEvents) {
          e.WhoId = target.Id;
          e.WhatId = target.AccountId;
        }
        update as system lineEvents;
      }
    } catch (DmlException e) {
      Database.rollback(savepoint);
      throw new LinkException(
        String.format(
          System.Label.LINE_Link_Failed,
          new List<Object>{ e.getDmlMessage(0) }
        )
      );
    }

    if (placeholder != null) {
      if (hasOtherRecords(placeholder.Id)) {
        result.placeholderKeptId = placeholder.Id;
      } else {
        result.placeholderDeleted = deletePlaceholder(placeholder.Id);
        if (!result.placeholderDeleted) {
          result.placeholderKeptId = placeholder.Id;
        }
      }
    }
    return result;
  }

  /**
   * Unlinks a conversation (03 §5 rule 4; the caller checks `LINE_Admin`). The Contact keeps the LINE user ID while
   * another conversation still links it, so auto-link can't immediately undo the unlink of one OA's conversation.
   *
   * @param conversationId the conversation to unlink
   */
  public static void unlink(Id conversationId) {
    LINE_Conversation__c conversation = [
      SELECT Id, Contact__c
      FROM LINE_Conversation__c
      WHERE Id = :conversationId
      WITH SYSTEM_MODE
    ];
    Id contactId = conversation.Contact__c;
    if (contactId == null) {
      return;
    }
    conversation.Contact__c = null;
    update as system conversation;
    Integer stillLinked = [
      SELECT COUNT()
      FROM LINE_Conversation__c
      WHERE Contact__c = :contactId
      WITH SYSTEM_MODE
    ];
    if (stillLinked == 0) {
      update as system new Contact(Id = contactId, LINE_User_Id__c = null);
    }
  }

  // "Nothing else attached" (DEC-34): details a person typed, or records that point at the Contact.
  private static Boolean hasOtherRecords(Id contactId) {
    Contact c = [
      SELECT Email, Phone, MobilePhone, Title, Description
      FROM Contact
      WHERE Id = :contactId
      WITH SYSTEM_MODE
    ];
    if (
      String.isNotBlank(c.Email) ||
      String.isNotBlank(c.Phone) ||
      String.isNotBlank(c.MobilePhone) ||
      String.isNotBlank(c.Title) ||
      String.isNotBlank(c.Description)
    ) {
      return true;
    }
    return [
        SELECT COUNT()
        FROM LINE_Conversation__c
        WHERE Contact__c = :contactId
        WITH SYSTEM_MODE
      ] > 0 ||
      [SELECT COUNT() FROM Task WHERE WhoId = :contactId WITH SYSTEM_MODE] >
      0 ||
      [SELECT COUNT() FROM Event WHERE WhoId = :contactId WITH SYSTEM_MODE] >
      0 ||
      [SELECT COUNT() FROM Case WHERE ContactId = :contactId WITH SYSTEM_MODE] >
      0 ||
      [
        SELECT COUNT()
        FROM OpportunityContactRole
        WHERE ContactId = :contactId
        WITH SYSTEM_MODE
      ] > 0 ||
      [
        SELECT COUNT()
        FROM ContentDocumentLink
        WHERE LinkedEntityId = :contactId
        WITH SYSTEM_MODE
      ] > 0;
  }

  // Partial success and logged (hard rule 7): a subscriber rule that blocks the delete only leaves the placeholder.
  private static Boolean deletePlaceholder(Id contactId) {
    List<Contact> toDelete = new List<Contact>{ new Contact(Id = contactId) };
    List<Database.DeleteResult> results = Database.delete(
      toDelete,
      false,
      AccessLevel.SYSTEM_MODE
    );
    if (!results[0].isSuccess()) {
      LineLogger.error(
        'LineLinkService.deletePlaceholder',
        results[0].getErrors()[0].getMessage(),
        null,
        contactId
      );
      return false;
    }
    return true;
  }

  /**
   * Resolves a Contact for each conversation that has none: an existing Contact holding the same LINE user ID,
   * otherwise a newly created one when `Auto_Create_Contact__c` is on.
   *
   * Makes no callouts, so it is safe to call between the callout and DML phases of a queueable.
   *
   * @param conversationIds conversations to resolve
   * @param displayNames LINE display name by conversation Id, from the profile callout; may be empty
   * @return the Contact Id by conversation Id, for conversations that gained one. Callers apply these to the
   *         conversation records they are about to update, so each conversation is still updated only once.
   */
  public static Map<Id, Id> resolveContacts(
    Set<Id> conversationIds,
    Map<Id, String> displayNames
  ) {
    Map<Id, Id> result = new Map<Id, Id>();
    if (conversationIds == null || conversationIds.isEmpty()) {
      return result;
    }
    Map<Id, String> names = displayNames == null
      ? new Map<Id, String>()
      : displayNames;

    List<LINE_Conversation__c> unlinked = [
      SELECT Id, Name, OwnerId, LINE_User_Id__c, LINE_OA_Configuration__c
      FROM LINE_Conversation__c
      WHERE Id IN :conversationIds AND Contact__c = NULL
      WITH SYSTEM_MODE
    ];
    if (unlinked.isEmpty()) {
      return result;
    }

    Set<String> lineUserIds = new Set<String>();
    for (LINE_Conversation__c c : unlinked) {
      if (String.isNotBlank(c.LINE_User_Id__c)) {
        lineUserIds.add(c.LINE_User_Id__c);
      }
    }
    if (lineUserIds.isEmpty()) {
      return result;
    }

    // Rule 2: a Contact already holding this LINE user ID wins, whether a rep linked it or we created it earlier.
    Map<String, Id> contactByLineUserId = new Map<String, Id>();
    for (Contact existing : [
      SELECT Id, LINE_User_Id__c
      FROM Contact
      WHERE LINE_User_Id__c IN :lineUserIds
      WITH SYSTEM_MODE
      ORDER BY CreatedDate ASC
    ]) {
      // The oldest wins if a subscriber has duplicates; LINE_User_Id__c is unique, so this is defensive only.
      if (!contactByLineUserId.containsKey(existing.LINE_User_Id__c)) {
        contactByLineUserId.put(existing.LINE_User_Id__c, existing.Id);
      }
    }

    List<LINE_Conversation__c> needContact = new List<LINE_Conversation__c>();
    for (LINE_Conversation__c c : unlinked) {
      Id contactId = contactByLineUserId.get(c.LINE_User_Id__c);
      if (contactId != null) {
        result.put(c.Id, contactId);
      } else if (String.isNotBlank(c.LINE_User_Id__c)) {
        needContact.add(c);
      }
    }

    if (!needContact.isEmpty() && LineSettings.autoCreateContact()) {
      result.putAll(createContacts(needContact, names));
    }
    return result;
  }

  // One Contact per LINE user ID. Two conversations for the same user (one per OA) share the Contact.
  private static Map<Id, Id> createContacts(
    List<LINE_Conversation__c> conversations,
    Map<Id, String> displayNames
  ) {
    Map<Id, Id> result = new Map<Id, Id>();
    Map<String, Contact> newByLineUserId = new Map<String, Contact>();
    Map<String, List<Id>> conversationsByLineUserId = new Map<String, List<Id>>();
    Id accountId = defaultAccountId();

    for (LINE_Conversation__c c : conversations) {
      String lineUserId = c.LINE_User_Id__c;
      if (!conversationsByLineUserId.containsKey(lineUserId)) {
        conversationsByLineUserId.put(lineUserId, new List<Id>());
      }
      conversationsByLineUserId.get(lineUserId).add(c.Id);
      if (newByLineUserId.containsKey(lineUserId)) {
        continue;
      }
      Contact contact = new Contact(
        LastName = lastNameFor(c, displayNames.get(c.Id)),
        LINE_User_Id__c = lineUserId,
        LINE_OA_Configuration__c = c.LINE_OA_Configuration__c,
        AccountId = accountId,
        // DEC-34: lets a later manual link recognise and remove this placeholder.
        LINE_Auto_Created__c = true
      );
      // The rep who owns the conversation owns the Contact; a queue-owned conversation leaves the default owner.
      if (c.OwnerId != null && c.OwnerId.getSObjectType() == User.SObjectType) {
        contact.OwnerId = c.OwnerId;
      }
      newByLineUserId.put(lineUserId, contact);
    }

    List<String> lineUserIds = new List<String>(newByLineUserId.keySet());
    List<Contact> toInsert = new List<Contact>();
    for (String lineUserId : lineUserIds) {
      toInsert.add(newByLineUserId.get(lineUserId));
    }
    List<Database.SaveResult> results = Database.insert(
      toInsert,
      false,
      AccessLevel.SYSTEM_MODE
    );
    LineLogger.saveErrors('LineLinkService.createContacts', results, toInsert);

    for (Integer i = 0; i < results.size(); i++) {
      if (!results[i].isSuccess()) {
        continue;
      }
      for (Id conversationId : conversationsByLineUserId.get(lineUserIds[i])) {
        result.put(conversationId, results[i].getId());
      }
    }
    return result;
  }

  // DEC-36: with Contact sharing Controlled by Parent, a Contact without an Account is visible only to its owner, so a
  // second rep whose conversation auto-links to it could never open it. A deleted default Account is logged and the
  // Contact is created without one, rather than failing the insert.
  private static Id defaultAccountId() {
    Id accountId = LineSettings.defaultAccountId();
    if (accountId == null) {
      return null;
    }
    List<Account> found = [
      SELECT Id
      FROM Account
      WHERE Id = :accountId
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    if (found.isEmpty()) {
      LineLogger.error(
        'LineLinkService.createContacts',
        'The default Account in LINE settings no longer exists; Contacts are created without an Account.',
        null,
        accountId
      );
      return null;
    }
    return accountId;
  }

  // LINE gives us a display name and nothing else, so it becomes the last name. Never blank: Contact requires one.
  private static String lastNameFor(
    LINE_Conversation__c conversation,
    String displayName
  ) {
    if (String.isNotBlank(displayName)) {
      return displayName.left(LAST_NAME_LENGTH);
    }
    if (String.isNotBlank(conversation.Name)) {
      return conversation.Name.left(LAST_NAME_LENGTH);
    }
    return conversation.LINE_User_Id__c.left(LAST_NAME_LENGTH);
  }
}
