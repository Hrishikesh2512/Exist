// Email is optional and free with any SMTP account, e.g. Gmail with an app password:
//   SMTP_HOST=smtp.gmail.com SMTP_PORT=465 SMTP_USER=you@gmail.com SMTP_PASS=<app password> SMTP_FROM="Exist <you@gmail.com>"
// Without it, "forgot password" tells people to ask their teacher or admin (who can reset it in the app).
import nodemailer, { type Transporter } from 'nodemailer';

let transport: Transporter | null = null;
export const sentMail: { to: string; subject: string; text: string }[] = []; // tests read this

export function emailEnabled(): boolean {
  return process.env.NODE_ENV === 'test' || !!(process.env.SMTP_HOST && process.env.SMTP_USER);
}

export async function sendMail(to: string, subject: string, text: string): Promise<void> {
  if (process.env.NODE_ENV === 'test') {
    sentMail.push({ to, subject, text });
    return;
  }
  transport ??= nodemailer.createTransport({
    host: process.env.SMTP_HOST,
    port: Number(process.env.SMTP_PORT ?? 465),
    secure: Number(process.env.SMTP_PORT ?? 465) === 465,
    auth: { user: process.env.SMTP_USER, pass: process.env.SMTP_PASS },
  });
  await transport.sendMail({ from: process.env.SMTP_FROM ?? process.env.SMTP_USER, to, subject, text });
}
