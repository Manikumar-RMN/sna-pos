"use client";

/**
 * A sign-in that is not part of any restaurant has nothing to open here. People are added to a
 * restaurant by its owner or manager (user code and password); new restaurants are set up by SNA.
 */
export function SetupForms({ email, contact }: { email: string; contact: string }) {
  return (
    <div className="space-y-4">
      <div className="card p-5 text-sm" style={{ color: "var(--color-ink-2)" }}>
        <h2 className="text-base font-bold">This sign-in is not part of a restaurant</h2>
        <p className="mt-2">
          Signed in as <b>{email}</b>. Ask your owner or manager to add you under <b>Settings → Users</b>. They will give you the restaurant code, your user
          code and a temporary password. Then sign out and sign in again with those.
        </p>
      </div>
      <div className="card p-5 text-sm" style={{ color: "var(--color-ink-2)" }}>
        <b>Want SNA POS for your own restaurant?</b> SNA sets up every new restaurant. Write to{" "}
        <a href={`mailto:${contact}`} className="font-bold" style={{ color: "var(--color-brand)" }}>
          {contact}
        </a>{" "}
        and you will get your sign-in from SNA.
      </div>
    </div>
  );
}
