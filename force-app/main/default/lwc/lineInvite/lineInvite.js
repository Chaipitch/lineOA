import { api } from "lwc";
import LightningModal from "lightning/modal";
import { loadScript } from "lightning/platformResourceLoader";
import QRCODE from "@salesforce/resourceUrl/qrcode";
import createInvite from "@salesforce/apex/LineChatController.createInvite";
import LOCALE from "@salesforce/i18n/locale";
import TIME_ZONE from "@salesforce/i18n/timeZone";

import TITLE from "@salesforce/label/c.LINE_Invite_Title";
import SCAN from "@salesforce/label/c.LINE_Invite_Scan";
import LINK from "@salesforce/label/c.LINE_Invite_Link";
import COPY from "@salesforce/label/c.LINE_Invite_Copy";
import COPIED from "@salesforce/label/c.LINE_Invite_Copied";
import EXPIRES from "@salesforce/label/c.LINE_Invite_Expires";
import NEW_CODE from "@salesforce/label/c.LINE_Invite_New_Code";
import CLOSE from "@salesforce/label/c.LINE_Invite_Close";
import THROUGH_OA from "@salesforce/label/c.LINE_Invite_Through_OA";
import GENERIC_ERROR from "@salesforce/label/c.LINE_Error_Generic";

const CANVAS_SIZE = 240;
const QUIET_ZONE_MODULES = 4;

/**
 * QR invite (03 §5 rule 5, D10): asks Apex for a one-time code, then draws the LINE link as a QR code on a canvas
 * with the bundled `qrcode` library. Nothing is loaded from a CDN, and no HTML is injected.
 */
export default class LineInvite extends LightningModal {
  @api contactId;

  invite;
  errorMessage;
  isLoading = true;
  copied = false;
  needsDraw = false;

  labels = {
    title: TITLE,
    scan: SCAN,
    link: LINK,
    newCode: NEW_CODE,
    close: CLOSE
  };

  connectedCallback() {
    this.generate();
  }

  renderedCallback() {
    if (this.needsDraw) {
      this.needsDraw = false;
      this.drawQr();
    }
  }

  async generate() {
    this.isLoading = true;
    this.copied = false;
    try {
      const [invite] = await Promise.all([
        createInvite({ contactId: this.contactId }),
        loadScript(this, QRCODE)
      ]);
      this.invite = invite;
      this.errorMessage = undefined;
      this.needsDraw = true;
    } catch (error) {
      this.invite = undefined;
      this.errorMessage = error?.body?.message || GENERIC_ERROR;
    } finally {
      this.isLoading = false;
    }
  }

  drawQr() {
    const canvas = this.template.querySelector("canvas");
    // The library defines a global `qrcode` factory when loaded.
    const factory = window.qrcode;
    if (!canvas || !factory || !this.invite) {
      return;
    }
    const qr = factory(0, "M");
    qr.addData(this.invite.url);
    qr.make();
    const count = qr.getModuleCount();
    const total = count + QUIET_ZONE_MODULES * 2;
    const cell = Math.floor(CANVAS_SIZE / total);
    const offset = Math.floor((CANVAS_SIZE - cell * count) / 2);
    const context = canvas.getContext ? canvas.getContext("2d") : null;
    if (!context) {
      return;
    }
    context.fillStyle = "#ffffff";
    context.fillRect(0, 0, CANVAS_SIZE, CANVAS_SIZE);
    context.fillStyle = "#000000";
    for (let row = 0; row < count; row++) {
      for (let col = 0; col < count; col++) {
        if (qr.isDark(row, col)) {
          context.fillRect(
            offset + col * cell,
            offset + row * cell,
            cell,
            cell
          );
        }
      }
    }
  }

  async handleCopy() {
    try {
      await navigator.clipboard.writeText(this.invite.url);
      this.copied = true;
    } catch {
      // Clipboard blocked: the link stays selectable in the field.
      this.copied = false;
    }
  }

  handleNewCode() {
    this.generate();
  }

  handleClose() {
    this.close();
  }

  get canvasSize() {
    return CANVAS_SIZE;
  }

  get copyLabel() {
    return this.copied ? COPIED : COPY;
  }

  get expiresText() {
    if (!this.invite?.expiresAt) {
      return "";
    }
    // The Salesforce user's locale and time zone, not the browser's.
    const formatted = new Intl.DateTimeFormat(LOCALE, {
      dateStyle: "medium",
      timeStyle: "short",
      timeZone: TIME_ZONE
    }).format(new Date(this.invite.expiresAt));
    return EXPIRES.replace("{0}", formatted);
  }

  get throughOaText() {
    return this.invite?.oaName
      ? THROUGH_OA.replace("{0}", this.invite.oaName)
      : "";
  }
}
