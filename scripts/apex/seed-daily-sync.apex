// Seeds a realistic LINE chat history in a SCRATCH org, to test the daily Activity History sync (M9) without a real
// LINE OA. No callouts are made and no secret is needed: the sync only reads stored messages.
//
// Creates (all tied to the fake channel 9000000001):
//   OA "May Sales OA", assigned to the first active LINE_Chat_User rep
//   Somchai Prasert (Account "Acme (LINE seed)"): 3 messages yesterday, as in the TA review doc 2.8, and 2 today
//   Niran Chaiyo (no Account): 2 messages today, one of them an image
//   An unlinked conversation (no Contact): 1 message yesterday, which must never get an Event
//
// Safe to re-run: it first deletes everything it created before, including the Events synced from it.
// Times are "local time in the org's default time zone" (Setup → Company Information), the zone that defines a day.
//
// Run:  sf apex run --file scripts/apex/seed-daily-sync.apex --target-org line-ns
// Scratch orgs only: in an installed package these classes and fields are not reachable from anonymous Apex.

String CHANNEL = '9000000001';

void out(String label, Object value) {
    System.debug(LoggingLevel.ERROR, 'SEED ' + label + ' = ' + value);
}

// Local wall-clock time on a day in the given zone → the instant.
Datetime at(TimeZone zone, Date day, Integer hour, Integer minute) {
    Datetime asIfUtc = Datetime.newInstanceGmt(day, Time.newInstance(hour, minute, 0, 0));
    return asIfUtc.addSeconds(-zone.getOffset(asIfUtc) / 1000);
}

LINE_Message__c message(Id conversationId, String direction, String type, String text, Datetime sentAt, Id senderId) {
    return new LINE_Message__c(
        LINE_Conversation__c = conversationId,
        Direction__c = direction,
        Message_Type__c = type,
        Text__c = text,
        Status__c = direction == 'Inbound' ? 'Received' : 'Sent',
        Sent_At__c = sentAt,
        Sender__c = senderId
    );
}

// 1. Remove an earlier seed. Messages go with their conversations (master-detail).
List<LINE_Conversation__c> oldConversations = [
    SELECT Id FROM LINE_Conversation__c WHERE LINE_OA_Configuration__r.Channel_Id__c = :CHANNEL
];
Set<Id> oldIds = new Map<Id, LINE_Conversation__c>(oldConversations).keySet();
delete [SELECT Id FROM Event WHERE LINE_Conversation__c IN :oldIds];
delete oldConversations;
delete [SELECT Id FROM Contact WHERE LINE_User_Id__c LIKE 'Useed%'];
delete [SELECT Id FROM Account WHERE Name = 'Acme (LINE seed)'];
delete [SELECT Id FROM LINE_OA_Configuration__c WHERE Channel_Id__c = :CHANNEL];

// 2. The rep, the OA, the customers
User rep = [
    SELECT Id, Name
    FROM User
    WHERE IsActive = TRUE
        AND Id IN (SELECT AssigneeId FROM PermissionSetAssignment WHERE PermissionSet.Name = 'LINE_Chat_User')
    ORDER BY Name
    LIMIT 1
];
LINE_OA_Configuration__c oa = new LINE_OA_Configuration__c(
    Name = 'May Sales OA',
    Channel_Id__c = CHANNEL,
    Bot_User_Id__c = 'Useedbot',
    Basic_Id__c = '@seedoa',
    Assigned_Rep__c = rep.Id,
    Is_Active__c = true
);
insert oa;
Account acme = new Account(Name = 'Acme (LINE seed)');
insert acme;
Contact somchai = new Contact(
    FirstName = 'Somchai', LastName = 'Prasert', AccountId = acme.Id,
    LINE_User_Id__c = 'Useed1', LINE_OA_Configuration__c = oa.Id
);
Contact niran = new Contact(
    FirstName = 'Niran', LastName = 'Chaiyo',
    LINE_User_Id__c = 'Useed2', LINE_OA_Configuration__c = oa.Id
);
insert new List<Contact>{ somchai, niran };

// 3. Conversations
TimeZone zone = LineDailyEventSyncBatch.orgTimeZone();
Date today = LineDailyEventSyncBatch.today(zone);
Date yesterday = today.addDays(-1);

LINE_Conversation__c withSomchai = new LINE_Conversation__c(
    Name = 'Somchai', LINE_OA_Configuration__c = oa.Id, LINE_User_Id__c = 'Useed1',
    Unique_Key__c = CHANNEL + ':Useed1', Contact__c = somchai.Id, OwnerId = rep.Id,
    Status__c = 'Following', Unread_Count__c = 0, Last_Message_At__c = at(zone, today, 9, 20)
);
LINE_Conversation__c withNiran = new LINE_Conversation__c(
    Name = 'Niran', LINE_OA_Configuration__c = oa.Id, LINE_User_Id__c = 'Useed2',
    Unique_Key__c = CHANNEL + ':Useed2', Contact__c = niran.Id, OwnerId = rep.Id,
    Status__c = 'Following', Unread_Count__c = 0, Last_Message_At__c = at(zone, today, 14, 2)
);
LINE_Conversation__c unlinked = new LINE_Conversation__c(
    Name = 'Unknown customer', LINE_OA_Configuration__c = oa.Id, LINE_User_Id__c = 'Useed3',
    Unique_Key__c = CHANNEL + ':Useed3', OwnerId = rep.Id,
    Status__c = 'Following', Unread_Count__c = 0, Last_Message_At__c = at(zone, yesterday, 11, 0)
);
insert new List<LINE_Conversation__c>{ withSomchai, withNiran, unlinked };

// 4. Messages
insert new List<LINE_Message__c>{
    // Yesterday: the example from the TA review document, 2.8
    message(withSomchai.Id, 'Inbound', 'text', 'Could you send the revised quotation?', at(zone, yesterday, 10, 1), null),
    message(withSomchai.Id, 'Outbound', 'text', 'Sure, I will send it today.', at(zone, yesterday, 10, 3), rep.Id),
    message(withSomchai.Id, 'Inbound', 'sticker', null, at(zone, yesterday, 10, 8), null),
    // Today
    message(withSomchai.Id, 'Inbound', 'text', 'Did you send it?', at(zone, today, 9, 15), null),
    message(withSomchai.Id, 'Outbound', 'text', 'Yes, just sent. Please check your email.', at(zone, today, 9, 20), rep.Id),
    message(withNiran.Id, 'Inbound', 'text', 'สวัสดีครับ ขอใบเสนอราคาหน่อยครับ', at(zone, today, 14, 0), null),
    message(withNiran.Id, 'Inbound', 'image', null, at(zone, today, 14, 2), null),
    // Never synced: no Contact
    message(unlinked.Id, 'Inbound', 'text', 'Hello?', at(zone, yesterday, 11, 0), null)
};

out('org time zone', zone.getID());
out('today', today);
out('yesterday', yesterday);
out('rep', rep.Name);
out('Somchai contact', somchai.Id);
out('Niran contact', niran.Id);
