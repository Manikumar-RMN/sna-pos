# Running SNA POS on your Mac

Everything is pre-filled. You should not need to copy or paste anything.

## Before you start

You need **Node.js 20 or newer**. Check by opening Terminal and typing:

```
node --version
```

If that says "command not found", download the **macOS Apple Silicon (arm64)**
installer from https://nodejs.org and run it, then try again.

## Run it

In Terminal, one line at a time:

```
cd ~/COMPANY/sna-pos/app
npm install
npm run dev
```

`npm install` takes a few minutes the first time. When `npm run dev` finishes
it prints a line like:

```
▲ Next.js 15.0.3
- Local: http://localhost:3000
```

Open **http://localhost:3000** in your browser.

To stop it, press **Control + C** in that Terminal window.

## First time through

1. You land on the sign-in page.
2. Type an email and a password (at least 8 characters), then click
   **Create an account**.
3. You are taken to the setup page. Fill in your restaurant's details and
   click **Create my restaurant**.
4. You land on the dashboard.

That one setup step creates your branch, five staff roles with their
permissions, India's GST tax groups, payment methods, receipt settings and a
billing device.

## What exists at this stage

- Sign in, sign out, create an account
- Restaurant setup
- Dashboard
- Users and roles, showing exactly what each role may do

Not built yet: menu management (Stage 3), billing and receipts (Stage 4),
offline billing (Stage 5).

## If something goes wrong

Copy the red error text from the Terminal or the browser and send it to Claude.
This code has **not been compiled or run by anyone yet** — npm was blocked in
the build environment — so one or two errors on the first run would be normal
rather than alarming.

## The environment file

`.env.local` is already filled in with your Supabase project's URL and
publishable key. Those two are safe to have in the browser: the key grants no
access by itself, because Row Level Security in the database is what protects
the data.

The **service-role key** is different — it bypasses every protection. It is not
in this project and must never be added to it.
