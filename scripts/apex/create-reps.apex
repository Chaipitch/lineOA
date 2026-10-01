// Template for scripts/create-reps.sh, which fills in the __PLACEHOLDERS__. Don't run it directly.
//
// Creates reps line.rep1 … line.repN, each with LINE_Chat_User, for multi-rep testing in the QA org or a scratch org.
// Idempotent: users are found again by a stable, org-unique username, so a rerun only adds what is missing.
// The profile is picked by permissions and licence key, never by name (profile names are localized in Thai orgs).
// Salesforce Platform seats are used first, so the org's few full Salesforce seats stay free.

Integer repCount = __COUNT__;
List<String> timeZones = new List<String>{ __TIME_ZONES__ };
String emailLocal = '__EMAIL_LOCAL__';
String emailDomain = '__EMAIL_DOMAIN__';
Boolean sendWelcome = __SEND_WELCOME__;

String orgKey = UserInfo.getOrganizationId().substring(0, 15).toLowerCase();

// Free seats per eligible profile, in order of preference (Platform first).
List<Id> profileIds = new List<Id>();
Map<Id, Id> licenceByProfile = new Map<Id, Id>();
Map<Id, Integer> freeByLicence = new Map<Id, Integer>();
for (ObjectPermissions op : [
    SELECT Parent.ProfileId, Parent.Profile.UserLicenseId, Parent.Profile.UserLicense.TotalLicenses,
        Parent.Profile.UserLicense.UsedLicenses
    FROM ObjectPermissions
    WHERE
        SobjectType = 'Contact'
        AND PermissionsEdit = TRUE
        AND Parent.IsOwnedByProfile = TRUE
        AND Parent.Profile.UserType = 'Standard'
        AND Parent.Profile.UserLicense.LicenseDefinitionKey IN ('SFDC', 'AUL')
        AND Parent.PermissionsModifyAllData = FALSE
    ORDER BY Parent.Profile.UserLicense.LicenseDefinitionKey, Parent.Profile.CreatedDate
]) {
    UserLicense lic = op.Parent.Profile.UserLicense;
    if (lic == null || licenceByProfile.containsKey(op.Parent.ProfileId)) {
        continue;
    }
    profileIds.add(op.Parent.ProfileId);
    licenceByProfile.put(op.Parent.ProfileId, op.Parent.Profile.UserLicenseId);
    freeByLicence.put(op.Parent.Profile.UserLicenseId, lic.TotalLicenses - lic.UsedLicenses);
}

Map<String, User> byUsername = new Map<String, User>();
for (Integer i = 1; i <= repCount; i++) {
    byUsername.put('line.rep' + i + '.' + orgKey + '@example.com', null);
}
for (User u : [SELECT Id, Username, IsActive FROM User WHERE Username IN :byUsername.keySet()]) {
    byUsername.put(u.Username, u);
}

List<User> toInsert = new List<User>();
for (Integer i = 1; i <= repCount; i++) {
    String username = 'line.rep' + i + '.' + orgKey + '@example.com';
    if (byUsername.get(username) != null) {
        continue;
    }
    Id profileId;
    for (Id candidate : profileIds) {
        Id licenceId = licenceByProfile.get(candidate);
        if (freeByLicence.get(licenceId) > 0) {
            profileId = candidate;
            freeByLicence.put(licenceId, freeByLicence.get(licenceId) - 1);
            break;
        }
    }
    if (profileId == null) {
        throw new IllegalArgumentException(
            'Out of Salesforce / Salesforce Platform seats after ' + (i - 1) + ' rep(s). ' +
            'See Setup → Company Information → User Licenses.'
        );
    }
    toInsert.add(
        new User(
            Username = username,
            // Plus-addressing sends every rep's welcome email to the one inbox.
            Email = emailLocal + '+linerep' + i + '@' + emailDomain,
            FirstName = 'Rep',
            LastName = String.valueOf(i),
            Alias = ('lrep' + i).left(8),
            ProfileId = profileId,
            TimeZoneSidKey = timeZones[Math.mod(i - 1, timeZones.size())],
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8'
        )
    );
}

if (!toInsert.isEmpty()) {
    Database.DMLOptions options = new Database.DMLOptions();
    // The welcome email carries the link to set a password, so the rep can log in.
    options.EmailHeader.triggerUserEmail = sendWelcome;
    Database.insert(toInsert, options);
    for (User u : toInsert) {
        byUsername.put(u.Username, u);
    }
}

List<PermissionSet> chatUser = [SELECT Id FROM PermissionSet WHERE Name = 'LINE_Chat_User' LIMIT 1];
if (chatUser.isEmpty()) {
    throw new IllegalArgumentException('Permission set LINE_Chat_User not found. Is the package installed?');
}
Set<Id> userIds = new Set<Id>();
for (User u : byUsername.values()) {
    userIds.add(u.Id);
}
Set<Id> assigned = new Set<Id>();
for (PermissionSetAssignment psa : [
    SELECT AssigneeId
    FROM PermissionSetAssignment
    WHERE PermissionSetId = :chatUser[0].Id AND AssigneeId IN :userIds
]) {
    assigned.add(psa.AssigneeId);
}
List<PermissionSetAssignment> psas = new List<PermissionSetAssignment>();
for (Id userId : userIds) {
    if (!assigned.contains(userId)) {
        psas.add(new PermissionSetAssignment(AssigneeId = userId, PermissionSetId = chatUser[0].Id));
    }
}
insert psas;

for (User u : [
    SELECT Username, Email, TimeZoneSidKey, Profile.UserLicense.Name, IsActive
    FROM User
    WHERE Id IN :userIds
    ORDER BY Username
]) {
    System.debug(
        LoggingLevel.ERROR,
        'LINE_REP ' + u.Username + ' | ' + u.Email + ' | ' + u.TimeZoneSidKey + ' | ' +
        u.Profile.UserLicense.Name + (u.IsActive ? '' : ' | INACTIVE')
    );
}
System.debug(LoggingLevel.ERROR, 'LINE_REP created ' + toInsert.size() + ', permission sets assigned ' + psas.size());
