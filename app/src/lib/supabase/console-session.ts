/**
 * The SNA console keeps its own sign-in, apart from the restaurant app's.
 *
 * Both live on the same web address, and a browser keeps one cookie per name.
 * With one shared name, signing in to a restaurant replaced the console
 * sign-in (and the other way round), so SNA staff could not have a restaurant
 * and the console open in the same browser. A second name gives the console
 * its own session, side by side with the restaurant one.
 */
export const CONSOLE_SESSION = "sb-sna-console-auth-token";
