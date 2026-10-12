"use client";

import { useState, type InputHTMLAttributes } from "react";

/**
 * A password box with a Show / Hide button, so the person can check what they typed.
 * Takes the same props as an <input>; the box is type="password" until Show is pressed.
 * Put the outer spacing (mb-4 …) in wrapperClassName; className styles the box itself.
 */
export function PasswordInput({
  wrapperClassName,
  className,
  ...props
}: Omit<InputHTMLAttributes<HTMLInputElement>, "type"> & { wrapperClassName?: string }) {
  const [shown, setShown] = useState(false);
  return (
    <div className={`relative ${wrapperClassName ?? ""}`}>
      <input {...props} type={shown ? "text" : "password"} className={`${className ?? "field"} pr-16`} autoCapitalize="off" autoCorrect="off" spellCheck={false} />
      <button
        type="button"
        onClick={() => setShown((s) => !s)}
        className="absolute inset-y-0 right-0 flex min-w-14 items-center justify-center px-3 text-xs font-bold"
        style={{ color: "var(--color-brand-strong, var(--color-brand))" }}
        aria-label={shown ? "Hide the password" : "Show the password"}
        aria-pressed={shown}
        aria-controls={props.id}
      >
        {shown ? "Hide" : "Show"}
      </button>
    </div>
  );
}
