// Prints a fresh sign-up code that belongs to nobody, for the first account on a new database or for
// inviting someone without asking an existing user. Uses the same DATABASE_URL / Cloud SQL settings
// as the server: `npm run signup-code`.
import { issueSignupCode } from "../src/auth.js";
import { openPool } from "../src/db.js";

const { pool, close } = await openPool();
try {
  const created = await issueSignupCode(pool, null);
  console.log(`${created.code}  (expires ${new Date(created.expiresAt).toISOString()})`);
} finally {
  await close();
}
