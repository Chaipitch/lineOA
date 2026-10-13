// Jest stand-in for lightning/modal, which sfdx-lwc-jest doesn't stub.
import { LightningElement, api } from "lwc";

export default class LightningModal extends LightningElement {
  @api label;
  @api size;
  @api description;

  close(result) {
    this.dispatchEvent(new CustomEvent("modalclose", { detail: result }));
  }
}

LightningModal.open = jest.fn().mockResolvedValue(undefined);
