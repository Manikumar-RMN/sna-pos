import { ConsolePasswordForm } from "./password-form";

export const dynamic = "force-dynamic";

/**
 * Change the password of the SNA console sign-in. Inside the console, so it uses
 * the console's own sign-in and never touches a restaurant sign-in in the same browser.
 */
export default async function ConsolePasswordPage({ searchParams }: { searchParams: Promise<{ recovery?: string }> }) {
  const { recovery } = await searchParams;
  return (
    <div className="mx-auto max-w-sm">
      <h1 className="text-2xl font-bold">{recovery ? "Choose a new password" : "Change password"}</h1>
      <p className="mt-1 mb-5 text-sm" style={{ color: "var(--color-ink-3)" }}>
        {recovery ? "You opened a password reset link. Choose a new password for the SNA console." : "For your SNA console sign-in."}
      </p>
      <ConsolePasswordForm />
    </div>
  );
}
