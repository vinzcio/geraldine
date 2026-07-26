interface OutboundEmail {
  to: string;
  subject: string;
  text: string;
}

const from = process.env.EMAIL_FROM ?? "Geraldine <no-reply@localhost>";
const resendApiKey = process.env.RESEND_API_KEY;

/**
 * Sends transactional mail. With no provider configured the message is printed
 * instead, so local sign-up works without wiring a mail service first.
 */
export async function sendEmail(email: OutboundEmail): Promise<void> {
  if (!resendApiKey) {
    console.info(
      `\n──── email (no provider configured) ────\n` +
        `to:      ${email.to}\n` +
        `subject: ${email.subject}\n\n${email.text}\n` +
        `────────────────────────────────────────\n`,
    );
    return;
  }

  const response = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${resendApiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from,
      to: [email.to],
      subject: email.subject,
      text: email.text,
    }),
  });

  if (!response.ok) {
    // Never log the body: verification and reset URLs are bearer credentials.
    throw new Error(`Email delivery failed with status ${response.status}`);
  }
}
