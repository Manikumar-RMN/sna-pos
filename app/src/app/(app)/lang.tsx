"use client";

import { createContext, useContext } from "react";
import { isRtl, second, type LangCode } from "@/lib/i18n";

const LangContext = createContext<LangCode | null>(null);

/** Makes the chosen second language available to every screen inside the app. */
export function LangProvider({ lang, children }: { lang: LangCode | null; children: React.ReactNode }) {
  return <LangContext.Provider value={lang}>{children}</LangContext.Provider>;
}

export function useLang(): LangCode | null {
  return useContext(LangContext);
}

/** Second-language word for an English screen word (null when none is set or known). */
export function useSecond(): (en: string) => string | null {
  const lang = useContext(LangContext);
  return (en: string) => second(lang, en);
}

/**
 * An English word with its second-language word in small type underneath.
 * English is always first; with no second language this is just the English text.
 */
export function Dual({ text, className }: { text: string; className?: string }) {
  const lang = useContext(LangContext);
  const s = second(lang, text);
  if (!s) return <>{text}</>;
  return (
    <span className={`inline-flex flex-col items-center leading-tight ${className ?? ""}`}>
      <span>{text}</span>
      <span className="text-[0.72em] font-semibold opacity-80" dir={isRtl(lang) ? "rtl" : undefined} lang={lang ?? undefined}>
        {s}
      </span>
    </span>
  );
}

/** A dish name with the name the restaurant typed in the second language underneath. */
export function DishName({ name, local }: { name: string; local?: string | null }) {
  const lang = useContext(LangContext);
  if (!local) return <>{name}</>;
  return (
    <span className="inline-flex flex-col leading-tight">
      <span>{name}</span>
      <span className="text-[0.8em] opacity-75" dir={isRtl(lang) ? "rtl" : undefined} lang={lang ?? undefined}>
        {local}
      </span>
    </span>
  );
}
