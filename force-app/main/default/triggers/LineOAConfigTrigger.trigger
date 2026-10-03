/**
 * Trigger for LINE OA configurations. No logic here (CLAUDE.md): see LineOAConfigTriggerHandler.
 */
trigger LineOAConfigTrigger on LINE_OA_Configuration__c(after delete) {
  new LineOAConfigTriggerHandler().run();
}
