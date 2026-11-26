"""The Mailer: sends the emails you approved, slowly and only once, and reads and sorts the replies.

Sending
  * Only drafts a person approved are sent, and the database's safety gate (send_blockers) is checked again
    right before each one. A draft that is blocked at that moment is held, with the reason, and you get an alert.
  * One email at a time, inside the mailbox's sending window (Monday to Friday, send_from_hour to
    send_until_hour in its time zone), at most daily_cap a day, with a random pause of min_gap_minutes or a
    little more between emails. New mailboxes should start low (10 to 15 a day) and grow slowly.
  * Every email gets the client's sender name and postal address, an unsubscribe link, and the one-click
    unsubscribe headers Gmail and Yahoo require. Follow-ups go out as replies in the same thread.
  * An email is marked as taken before it is handed to the mail server, so a crash can never send it twice.
    (If that ever happens mid-send, you get an alert to check the Sent folder.)

Replies
  * Reads new messages in the inbox (it does not mark them as read), matches each to the buyer we wrote to,
    and sorts it: interested, question, not now, wrong person, not interested, unsubscribe, out of office, other.
  * Any real reply stops that buyer's automatic follow-ups (the database's apply_reply() does this, the same way
    for replies you log by hand). "Unsubscribe" or "stop" ends all outreach to them on every channel. "Not now"
    snoozes them for the campaign's snooze_days. Interested buyers and questions raise an urgent alert; the
    Writer drafts an answer for your approval and, for interested buyers, the Meeting briefer writes a brief.
  * Answers and check-ins go out as replies in the buyer's own thread.
  * Bounces mark the address invalid.

Run:
  python -m agents.mailer send --once      send what is due now, then stop
  python -m agents.mailer replies          read and sort new replies once
  python -m agents.mailer run              both, every few minutes (the team runner also does this)
  python -m agents.mailer setup            create or update the mailbox row from your .env settings
Settings (.env): MAIL_ADDRESS, MAIL_PASSWORD, MAIL_DISPLAY_NAME, SMTP_HOST, SMTP_PORT, IMAP_HOST, UNSUBSCRIBE_URL.
MAIL_DRY_RUN=1 writes each email to out/mail/ instead of sending it (nothing leaves the computer).
"""
from __future__ import annotations

import argparse
import datetime as dt
import email
import email.policy
import email.utils
import imaplib
import os
import pathlib
import random
import re
import smtplib
import time
from email.message import EmailMessage
from typing import Literal, Optional
from zoneinfo import ZoneInfo

from pydantic import BaseModel, Field

from . import teamdb as db
from .common import FALLBACK_BETA, Usage

OUT = pathlib.Path(os.environ.get("SBM_OUT", "out")) / "mail"


# ─────────────────────────── settings ───────────────────────────
def settings() -> dict:
    addr = (os.environ.get("MAIL_ADDRESS") or "").strip().lower()
    return {
        "address": addr,
        "password": os.environ.get("MAIL_PASSWORD") or "",
        "display_name": os.environ.get("MAIL_DISPLAY_NAME") or addr.split("@")[0].title(),
        "smtp_host": os.environ.get("SMTP_HOST", "smtp.gmail.com"),
        "smtp_port": int(os.environ.get("SMTP_PORT", "465")),
        "imap_host": os.environ.get("IMAP_HOST", "imap.gmail.com"),
        "unsubscribe_url": (os.environ.get("UNSUBSCRIBE_URL") or "").rstrip("/"),
        "dry_run": os.environ.get("MAIL_DRY_RUN", "") not in ("", "0", "false"),
    }


def mailbox(conn, cfg: dict) -> dict:
    if not cfg["address"]:
        raise SystemExit("MAIL_ADDRESS is not set (see .env.example).")
    row = db.one(conn, "select * from mailboxes where address = %s", (cfg["address"],))
    if not row:
        row = db.one(conn, "insert into mailboxes (address, display_name) values (%s, %s) returning *",
                     (cfg["address"], cfg["display_name"]))
    return row


# ─────────────────────────── building an email ───────────────────────────
def footer(draft: dict, cfg: dict) -> str:
    who = ", ".join(x for x in [draft["sender_name"], draft["sender_company"]] if x)
    link = f"{cfg['unsubscribe_url']}/u/{draft['unsubscribe_token']}"
    return (f"\n\n--\n{who}\n{draft['postal_address']}\n"
            f"If you'd rather not hear from us, reply \"unsubscribe\" or use this link: {link}")


def build(draft: dict, cfg: dict, box: dict, first: Optional[dict]) -> EmailMessage:
    msg = EmailMessage()
    msg["From"] = email.utils.formataddr((box["display_name"], box["address"]))
    to_name = " ".join(x for x in [draft["first_name"], draft["last_name"]] if x)
    msg["To"] = email.utils.formataddr((to_name, draft["email"])) if to_name else draft["email"]
    subject = draft["subject"]
    if (draft["step"] > 1 or draft.get("purpose") in ("reply", "check_in")) and first:
        subject = subject or ("Re: " + re.sub(r"^(re:\s*)+", "", first["subject"] or "", flags=re.I))
        if first.get("message_id"):
            msg["In-Reply-To"] = first["message_id"]
            msg["References"] = first.get("references") or first["message_id"]
    msg["Subject"] = subject or ""
    msg["Date"] = email.utils.formatdate(localtime=False)
    msg["Message-ID"] = email.utils.make_msgid(domain=box["address"].split("@")[1])
    link = f"{cfg['unsubscribe_url']}/u/{draft['unsubscribe_token']}"
    msg["List-Unsubscribe"] = f"<{link}/one-click>, <mailto:{box['address']}?subject=unsubscribe>"
    msg["List-Unsubscribe-Post"] = "List-Unsubscribe=One-Click"
    msg.set_content(draft["body"].rstrip() + footer(draft, cfg))
    return msg


# ─────────────────────────── sending ───────────────────────────
DRAFT_SQL = """
    select d.*, c.email, c.first_name, c.last_name, c.unsubscribe_token,
           cl.name as client, cl.sender_name, cl.sender_company, cl.postal_address
    from outreach_drafts d join contacts c on c.id = d.contact_id join clients cl on cl.id = d.client_id
    where d.id = %s"""


def in_window(box: dict, now: dt.datetime) -> bool:
    local = now.astimezone(ZoneInfo(box["timezone"]))
    return local.weekday() < 5 and box["send_from_hour"] <= local.hour < box["send_until_hour"]


def sent_today(conn, box: dict) -> int:
    return db.one(conn, """select count(*) as n from outreach_drafts where mailbox_id = %s and send_claimed_at is not null
                           and (send_claimed_at at time zone %s)::date = (now() at time zone %s)::date""",
                  (box["id"], box["timezone"], box["timezone"]))["n"]


def send_due(conn, cfg: dict, now: Optional[dt.datetime] = None, smtp_factory=None, log=print) -> int:
    """Send at most one email, if one is due and the mailbox allows it now. Returns how many were sent (0 or 1)."""
    now = now or dt.datetime.now(dt.timezone.utc)
    box = mailbox(conn, cfg)
    if box["paused"] or not in_window(box, now):
        return 0
    if box["next_send_at"] and box["next_send_at"] > now:
        return 0
    if sent_today(conn, box) >= box["daily_cap"]:
        return 0
    if not cfg["unsubscribe_url"] and not cfg["dry_run"]:
        db.alert(conn, "mail_setup", "Emails are approved but UNSUBSCRIBE_URL is not set, so nothing is sent. "
                 "Set it to the dashboard's web address in .env.", severity="urgent", dedupe_key="mail_setup:unsub")
        return 0

    for cand in db.all_rows(conn, """
            select id from outreach_drafts
            where status = 'approved' and channel = 'email' and send_claimed_at is null
              and (send_after is null or send_after <= now())
            order by step desc, reviewed_at limit 20"""):
        why = db.one(conn, "select send_blockers(%s) as why", (cand["id"],))["why"]
        if why:
            reason = " ".join(why)
            row = db.one(conn, "update outreach_drafts set send_error = %s where id = %s and send_error is distinct from %s "
                               "returning id", (reason, cand["id"], reason))
            if row:
                db.alert(conn, "send_held", f"An approved email is held and will not be sent: {reason}",
                         refs={"draft_id": str(cand["id"])}, dedupe_key=f"held:{cand['id']}")
            continue
        # Take it. From here it is never picked again, even if the computer crashes mid-send.
        took = db.one(conn, "update outreach_drafts set send_claimed_at = now(), mailbox_id = %s, send_error = null "
                            "where id = %s and send_claimed_at is null and status = 'approved' returning id",
                      (box["id"], cand["id"]))
        if not took:
            continue
        return _send_one(conn, cfg, box, cand["id"], now, smtp_factory, log)
    return 0


def _send_one(conn, cfg, box, draft_id, now, smtp_factory, log) -> int:
    d = db.one(conn, DRAFT_SQL, (draft_id,))
    first = None
    if d.get("purpose") in ("reply", "check_in") and d.get("reply_to_interaction_id"):
        rep = db.one(conn, "select subject, external_id from interactions where id = %s and channel = 'email'",
                     (d["reply_to_interaction_id"],))
        orig = db.one(conn, "select message_id from outreach_drafts where contact_id = %s and campaign_id is not distinct from %s "
                            "and channel = 'email' and step = 1 and status = 'sent'", (d["contact_id"], d["campaign_id"]))
        if rep and rep["external_id"]:
            refs = " ".join(x for x in [(orig or {}).get("message_id"), rep["external_id"]] if x)
            first = {"subject": rep["subject"], "message_id": rep["external_id"], "references": refs}
    elif d["step"] > 1:
        first = db.one(conn, "select subject, message_id from outreach_drafts where contact_id = %s and campaign_id "
                             "is not distinct from %s and channel = 'email' and step = 1 and status = 'sent'",
                       (d["contact_id"], d["campaign_id"]))
    msg = build(d, cfg, box, first)
    try:
        if cfg["dry_run"]:
            OUT.mkdir(parents=True, exist_ok=True)
            (OUT / f"{now:%Y%m%d-%H%M%S}-{str(draft_id)[:8]}.eml").write_bytes(msg.as_bytes())
        else:
            factory = smtp_factory or (lambda: smtplib.SMTP_SSL(cfg["smtp_host"], cfg["smtp_port"], timeout=60)
                                       if cfg["smtp_port"] == 465 else smtplib.SMTP(cfg["smtp_host"], cfg["smtp_port"], timeout=60))
            with factory() as s:
                if cfg["smtp_port"] != 465:
                    s.starttls()
                s.login(cfg["address"], cfg["password"])
                s.send_message(msg)
    except smtplib.SMTPRecipientsRefused as exc:
        # The server refused this address: nothing was sent. Mark it so nobody tries again.
        db.all_rows(conn, "update contacts set email_status = 'invalid' where id = %s", (d["contact_id"],))
        db.all_rows(conn, "update outreach_drafts set status = 'cancelled', send_error = %s where id = %s",
                    (f"The mail server refused the address: {exc}"[:500], draft_id))
        log(f"  refused: {d['email']}")
        return 0
    except (smtplib.SMTPException, OSError) as exc:
        # Nothing was accepted by the server, so it is safe to put the email back for a later try.
        db.all_rows(conn, "update outreach_drafts set send_claimed_at = null, send_error = %s where id = %s",
                    (f"{type(exc).__name__}: {exc}"[:500], draft_id))
        db.all_rows(conn, "update mailboxes set next_send_at = now() + interval '30 minutes' where id = %s", (box["id"],))
        db.alert(conn, "send_failed", f"Sending failed and will be retried in 30 minutes: {type(exc).__name__}: {exc}",
                 severity="urgent", dedupe_key=f"send_failed:{dt.date.today()}")
        return 0

    with conn.transaction():
        it = db.one(conn, """insert into interactions (client_id, campaign_id, company_id, contact_id, channel, direction, kind,
                                                       actor, agent_id, subject, body, external_id, metadata)
                             values (%s, %s, %s, %s, 'email', 'outbound', 'sent', 'bot', %s, %s, %s, %s, %s)
                             on conflict (channel, external_id) do nothing returning id""",
                     (d["client_id"], d["campaign_id"], d["company_id"], d["contact_id"], d["writer_agent_id"],
                      msg["Subject"], msg.get_content(), msg["Message-ID"],
                      db.jsonb({"draft_id": str(draft_id), "step": d["step"], "approved_by": d["reviewed_by"],
                                "mailbox": box["address"], "dry_run": cfg["dry_run"]})))
        db.all_rows(conn, """update outreach_drafts set status = 'sent', sent_at = now(), message_id = %s, interaction_id = %s,
                                    subject = coalesce(subject, %s) where id = %s""",
                    (msg["Message-ID"], it["id"] if it else None, msg["Subject"], draft_id))
        if d["campaign_id"]:
            db.all_rows(conn, "update campaign_targets set status = 'contacted', updated_at = now() "
                              "where campaign_id = %s and contact_id = %s and status = 'queued'", (d["campaign_id"], d["contact_id"]))
        gap = box["min_gap_minutes"] * random.uniform(1.0, 1.7)
        db.all_rows(conn, "update mailboxes set next_send_at = now() + make_interval(secs => %s) where id = %s",
                    (gap * 60, box["id"]))
    which = "first email" if d["step"] == 1 else f"follow-up {d['step'] - 1}"
    log(f"  {'wrote' if cfg['dry_run'] else 'sent'}: {d['email']} ({which})")
    return 1


# ─────────────────────────── replies ───────────────────────────
Category = Literal["interested", "question", "not_now", "wrong_person", "not_interested", "unsubscribe",
                   "out_of_office", "other"]


class ReplySort(BaseModel):
    category: Category = Field(description="What the buyer is saying")
    summary: str = Field(description="One plain sentence: what they said and what they want")
    referral: Optional[str] = Field(None, description="If they point to someone else: that person's name and email, else null")


SORT_SYSTEM = """You sort replies to wholesale sales emails. Pick ONE category:
interested     wants samples, prices, a call, a catalog, or to order
question       asks something specific before deciding
not_now        maybe later, timing is wrong, already stocked for the season
wrong_person   not their area; may name who is
not_interested a clear no, without asking to stop all contact
unsubscribe    asks to stop emailing, be removed, or complains about being contacted (any language)
out_of_office  automatic away or holiday reply
other          anything else
When unsure between not_interested and unsubscribe, choose unsubscribe."""

STOP_WORDS = re.compile(r"\b(unsubscribe|remove me|take me off|stop (emailing|contacting|writing)|do not (email|contact)|"
                        r"don'?t (email|contact)|opt[ -]?out|darse de baja|baja|d[ée]sinscri|désabonner|abmelden|"
                        r"nicht mehr (kontaktieren|schreiben)|cancella(mi|re)|no me escrib)", re.I)
AUTO_SUBJECT = re.compile(r"^(automatic reply|auto[- ]?reply|out of (the )?office|abwesenheit|absence|"
                          r"respuesta autom[aá]tica|fuera de la oficina|r[ée]ponse automatique|risposta automatica)", re.I)


def _text(m: email.message.EmailMessage) -> str:
    part = m.get_body(preferencelist=("plain", "html"))
    if part is None:
        return ""
    body = part.get_content()
    if part.get_content_type() == "text/html":
        body = re.sub(r"<[^>]+>", " ", body)
    # keep only the new part, not the quoted email below it
    body = re.split(r"\n(?:On .{5,200}wrote:|El .{5,200}escribi[oó]:|Le .{5,200}a écrit|Am .{5,200}schrieb|-----Original Message-----|>)",
                    body, maxsplit=1)[0]
    return body.strip()[:4000]


def _bounced_address(m) -> Optional[str]:
    if m.get("X-Failed-Recipients"):
        return m["X-Failed-Recipients"].split(",")[0].strip().lower()
    for part in m.walk():
        if part.get_content_type() in ("message/delivery-status",):
            raw = part.as_string()
            hit = re.search(r"Final-Recipient:\s*rfc822;\s*([^\s>]+)", raw, re.I)
            if hit:
                return hit.group(1).strip().lower()
    return None


def handle_message(conn, raw: bytes, ai=None, usage: Optional[Usage] = None, sort_model: str = "") -> str:
    """File one incoming email. Returns what was done, for the log."""
    m = email.message_from_bytes(raw, policy=email.policy.default)
    sender = (email.utils.parseaddr(m.get("From", ""))[1] or "").lower()
    msg_id = m.get("Message-ID") or f"<no-id-{hash(raw)}@local>"
    ctype = m.get_content_type()

    # Bounces
    if re.match(r"(mailer-daemon|postmaster)@", sender) or ctype == "multipart/report":
        addr = _bounced_address(m)
        c = db.one(conn, "select id, company_id from contacts where lower(email) = %s", (addr,)) if addr else None
        if not c:
            return "bounce for an unknown address"
        db.all_rows(conn, "update contacts set email_status = 'invalid' where id = %s", (c["id"],))
        last = db.one(conn, "select client_id, campaign_id from interactions where contact_id = %s and kind = 'sent' "
                            "order by occurred_at desc limit 1", (c["id"],))
        if last:
            db.all_rows(conn, """insert into interactions (client_id, campaign_id, company_id, contact_id, channel, direction,
                                                           kind, actor, external_id) values (%s, %s, %s, %s, 'email', 'inbound',
                                                           'bounce', 'system', %s) on conflict do nothing""",
                        (last["client_id"], last["campaign_id"], c["company_id"], c["id"], msg_id))
        db.all_rows(conn, "update outreach_drafts set status = 'cancelled', review_note = 'Address bounced' "
                          "where contact_id = %s and status in ('pending_review','approved') and channel = 'email'", (c["id"],))
        return f"bounce: {addr} marked invalid"

    # Which email of ours is this answering?
    refs = " ".join(filter(None, [m.get("In-Reply-To"), m.get("References")]))
    ids = re.findall(r"<[^>]+>", refs)
    sent = db.one(conn, """select i.client_id, i.campaign_id, i.company_id, i.contact_id from interactions i
                           where i.kind = 'sent' and i.channel = 'email' and i.external_id = any(%s)
                           order by i.occurred_at desc limit 1""", (ids,)) if ids else None
    if not sent and sender:
        sent = db.one(conn, """select i.client_id, i.campaign_id, i.company_id, i.contact_id from interactions i
                               join contacts c on c.id = i.contact_id
                               where i.kind = 'sent' and i.channel = 'email' and lower(c.email) = %s
                               order by i.occurred_at desc limit 1""", (sender,))
    if not sent:
        return f"not a reply to our outreach ({sender})"
    if db.one(conn, "select 1 from interactions where channel = 'email' and external_id = %s", (msg_id,)):
        return "already filed"

    subject = m.get("Subject", "")
    text = _text(m)
    auto = (m.get("Auto-Submitted", "no").lower() != "no" or m.get("X-Autoreply") or m.get("X-Autorespond")
            or (m.get("Precedence", "").lower() in ("auto_reply", "bulk", "junk")) or AUTO_SUBJECT.search(subject))
    if auto:
        sort = ReplySort(category="out_of_office", summary="Automatic reply.")
    elif STOP_WORDS.search(text) or STOP_WORDS.search(subject):
        sort = ReplySort(category="unsubscribe", summary="Asked us to stop contacting them.")
    elif ai is not None:
        sort = _ai_sort(ai, usage, sort_model, subject, text)
    else:
        sort = ReplySort(category="other", summary="Not sorted (no AI key); please read it.")

    kind = "reply" if sort.category != "out_of_office" else "note"
    filed = db.one(conn, """insert into interactions (client_id, campaign_id, company_id, contact_id, channel, direction, kind, actor,
                                                   subject, body, external_id, metadata)
                         values (%s, %s, %s, %s, 'email', 'inbound', %s::interaction_kind, 'buyer', %s, %s, %s, %s)
                         on conflict (channel, external_id) do nothing returning id""",
                (sent["client_id"], sent["campaign_id"], sent["company_id"], sent["contact_id"], kind, subject, text, msg_id,
                 db.jsonb({"category": sort.category, "summary": sort.summary, "referral": sort.referral, "from": sender})))
    who = db.one(conn, "select trim(coalesce(c.first_name,'') || ' ' || coalesce(c.last_name,'')) as name, co.name as company "
                       "from contacts c left join companies co on co.id = c.company_id where c.id = %s", (sent["contact_id"],))
    label = ", ".join(x for x in [who["name"], who["company"]] if x) or sender

    if sort.category == "out_of_office":
        return f"out of office: {label}"
    # A real answer: no more automatic follow-ups; unsubscribe stops everything; "not now" snoozes (see apply_reply).
    if filed:
        db.one(conn, "select apply_reply(%s) as r", (filed["id"],))
    if sort.category == "unsubscribe":
        return f"unsubscribe: {label} stopped everywhere"
    if sort.category in ("interested", "question"):
        nxt = ("The Writer is drafting an answer for your approval (Drafts page)"
               + (" and a meeting brief (Meetings page)." if sort.category == "interested" else "."))
        db.alert(conn, "buyer_replied", f"{label} replied ({sort.category.replace('_', ' ')}): {sort.summary} {nxt}",
                 severity="urgent", client_id=sent["client_id"],
                 refs={"contact_id": str(sent["contact_id"]), "message_id": msg_id})
    elif sort.category in ("wrong_person", "other", "not_now"):
        extra = f" They suggested: {sort.referral}." if sort.referral else ""
        db.alert(conn, "buyer_replied", f"{label} replied ({sort.category.replace('_', ' ')}): {sort.summary}{extra}",
                 client_id=sent["client_id"], refs={"contact_id": str(sent["contact_id"]), "message_id": msg_id})
    return f"{sort.category}: {label}"


def _ai_sort(ai, usage: Usage, mdl: str, subject: str, text: str) -> ReplySort:
    for _ in range(2):
        try:
            resp = ai.beta.messages.parse(model=mdl, max_tokens=2000, system=SORT_SYSTEM,
                                          messages=[{"role": "user", "content": f"Subject: {subject}\n\n{text}"}],
                                          output_format=ReplySort, output_config={"effort": "low"},
                                          betas=[FALLBACK_BETA], fallbacks="default")
        except ValueError:
            continue
        if usage is not None:
            usage.add(resp)
        if resp.parsed_output is not None:
            return resp.parsed_output
    return ReplySort(category="other", summary="Could not sort this reply; please read it.")


def read_replies(conn, cfg: dict, ai=None, imap_factory=None, log=print) -> int:
    """Read new inbox messages since the last run and file them. Returns how many were filed."""
    box = mailbox(conn, cfg)
    usage = Usage()
    mdl = db.TEAM["reviewer"][1]
    filed = 0
    imap = None
    try:
        try:
            imap = (imap_factory or (lambda: imaplib.IMAP4_SSL(cfg["imap_host"], timeout=60)))()
            imap.login(cfg["address"], cfg["password"])
        except (imaplib.IMAP4.error, OSError) as exc:
            db.alert(conn, "mail_login", f"Could not read the mailbox {cfg['address']} for replies: {exc}. Check MAIL_PASSWORD "
                     "(Google Workspace: an app password) and IMAP_HOST.", severity="urgent", dedupe_key=f"imap:{dt.date.today()}")
            return 0
        imap.select("INBOX", readonly=True)
        typ, data = imap.uid("search", None, f"UID {box['imap_last_uid'] + 1}:*")
        uids = [int(u) for u in (data[0] or b"").split() if int(u) > box["imap_last_uid"]]
        if box["imap_last_uid"] == 0 and uids:
            uids = uids[-200:]   # first run: only look at recent mail
        for uid in uids:
            typ, parts = imap.uid("fetch", str(uid), "(BODY.PEEK[])")
            raw = next((p[1] for p in parts if isinstance(p, tuple)), None)
            if raw:
                result = handle_message(conn, raw, ai, usage, mdl)
                log(f"  reply {uid}: {result}")
                filed += not result.startswith(("not a reply", "already"))
            db.all_rows(conn, "update mailboxes set imap_last_uid = greatest(imap_last_uid, %s) where id = %s", (uid, box["id"]))
    finally:
        try:
            if imap is not None:
                imap.logout()
        except Exception:
            pass
    if usage.input_tokens:
        db.record_run(conn, "reviewer", usage, f"sorted {filed} replies")
    return filed


# ─────────────────────────── command line ───────────────────────────
def main(argv=None) -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("send", help="send approved emails that are due")
    s.add_argument("--once", action="store_true")
    sub.add_parser("replies", help="read and sort new replies")
    r = sub.add_parser("run", help="send and read replies every few minutes")
    r.add_argument("--interval", type=int, default=120)
    sub.add_parser("setup", help="create the mailbox row from .env")
    args = ap.parse_args(argv)

    cfg = settings()
    conn = db.connect()
    db.register_team(conn)
    box = mailbox(conn, cfg)
    if args.cmd == "setup":
        db.all_rows(conn, "update mailboxes set display_name = %s where id = %s", (cfg["display_name"], box["id"]))
        print(f"Mailbox {box['address']}: up to {box['daily_cap']} emails a day, {box['send_from_hour']}:00 to "
              f"{box['send_until_hour']}:00 {box['timezone']}, Monday to Friday. Change these in the dashboard's Sending page.")
        return
    ai = None
    if os.environ.get("ANTHROPIC_API_KEY"):
        from .common import client
        ai = client()
    log = lambda m: print(f"{dt.datetime.now():%H:%M:%S} {m}", flush=True)
    while True:
        if args.cmd in ("send", "run"):
            while send_due(conn, cfg, log=log):
                if args.cmd == "send" and args.once:
                    break
        if args.cmd in ("replies", "run"):
            read_replies(conn, cfg, ai, log=log)
        if args.cmd != "run":
            break
        time.sleep(args.interval)


if __name__ == "__main__":
    main()
