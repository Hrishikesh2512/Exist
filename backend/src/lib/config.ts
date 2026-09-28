export const config = {
  port: Number(process.env.PORT ?? 8080),
  jwtSecret: process.env.JWT_SECRET ?? (process.env.NODE_ENV === 'production' ? '' : 'dev-only-secret-change-me'),
  zone: process.env.INSTITUTION_TZ ?? 'Asia/Kolkata',
  /** dev: skip · record: verify phones and show admins the result (default) · strict: refuse phones that fail. */
  attestationMode: (process.env.ATTESTATION_MODE ?? 'record') as 'dev' | 'record' | 'strict',
  /** Base64 key used to encrypt session secrets at rest (32 bytes). */
  secretsKey: process.env.SECRETS_KEY ?? '',
};
if (!config.jwtSecret) throw new Error('JWT_SECRET must be set in production');
