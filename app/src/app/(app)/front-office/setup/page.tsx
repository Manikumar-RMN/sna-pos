import { redirect } from "next/navigation";

/** Setup lives under Settings now; old links and bookmarks land there. */
export default function FoSetupMoved() {
  redirect("/settings/front-office");
}
