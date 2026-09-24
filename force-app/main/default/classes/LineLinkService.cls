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
        LINE_OA_Configuration__c = c.LINE_OA_Configuration__c
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
