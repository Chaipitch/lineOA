/**
 * Handler for `LineOAConfigTrigger` on `LINE_OA_Configuration__c`.
 *
 * After delete: deletes the channel secrets of the deleted OAs (DEC-33), so no secret outlives its OA whichever way the
 * record is deleted (UI, API, data loader). Conversations already block deleting an OA that has history, so this only
 * runs for OAs without any. M8 adds the reassignment batch on rep or active changes.
 *
 * `without sharing` (02 §2): runs for whoever deletes the record, and the protected credential setting is reachable
 * only from package code in system mode.
 */
public without sharing class LineOAConfigTriggerHandler extends LineTriggerHandler {
  @TestVisible
  private List<LINE_OA_Configuration__c> deleted;

  /**
   * Uses the trigger context.
   */
  public LineOAConfigTriggerHandler() {
    this((List<LINE_OA_Configuration__c>) Trigger.old);
  }

  /**
   * @param deleted the deleted OA configurations
   */
  @TestVisible
  private LineOAConfigTriggerHandler(List<LINE_OA_Configuration__c> deleted) {
    this.deleted = deleted;
  }

  protected override void afterDelete() {
    Set<String> channelIds = new Set<String>();
    for (LINE_OA_Configuration__c oa : deleted) {
      if (String.isNotBlank(oa.Channel_Id__c)) {
        channelIds.add(oa.Channel_Id__c);
      }
    }
    LineCredentialStore.removeAll(channelIds);
  }
}
