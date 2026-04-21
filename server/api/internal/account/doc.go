// Package account will own the magic-link email auth flow in Phase 1:
//
//   - accept an email, generate a signed short-lived token, mail it via a
//     transactional provider (Postmark / Resend / SES), and verify the token
//     on return.
//   - the token lives only in the signature (HMAC(secret, email+expiry+nonce))
//     so we never persist a "session" that could be seized.
//
// Phase 0 leaves this empty on purpose; device provisioning in internal/http
// currently trusts a raw email, which is fine because Stripe webhook is the
// only way an email ever gets a tier in the DB.
package account
