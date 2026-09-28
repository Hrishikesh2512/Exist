# Launching Exist for your institution

This takes about an hour, once. Everything is free. After it, nobody ever deals with a "server":
teachers create classes in the app, students join with a code, and attendance works.

What you will have:
- `https://<yourname>.duckdns.org`: the website (app download, attendance sheets).
- **Exist** on students' and teachers' phones, already pointed at your server.

---

## Step 1: Get a free always-on server (Oracle Cloud "Always Free")

1. Sign up at **cloud.oracle.com** → *Start for free*. A card is asked for identity verification only;
   Always Free resources are never charged.
2. **Create a VM instance** (Menu → Compute → Instances → *Create instance*):
   - Image: **Ubuntu 22.04** (or 24.04)
   - Shape: **Ampere (VM.Standard.A1.Flex)**, 1 OCPU, 6 GB RAM (all within Always Free)
   - Download the **SSH private key** it offers.
3. **Open the web ports:** on the instance page → *Subnet* → *Default Security List* → *Add Ingress Rules*:
   source `0.0.0.0/0`, TCP, destination ports **80,443**.
4. Note the instance's **Public IP address**.

## Step 2: Get a free web address (DuckDNS)

1. Go to **duckdns.org** and sign in (with Google or GitHub).
2. Add a subdomain, e.g. `myschool` → `myschool.duckdns.org`.
3. Put your server's **Public IP** in the *current ip* box → *update ip*.

## Step 3: Put Exist on the server (one command)

On your computer, in the Exist folder:

```bash
./deploy/package.sh                                   # makes exist-server.tgz (small)
scp -i <your-ssh-key> exist-server.tgz ubuntu@<public-ip>:
ssh -i <your-ssh-key> ubuntu@<public-ip>
```

Then, on the server:

```bash
tar xzf exist-server.tgz && cd exist
sudo ./deploy/setup.sh
```

It asks for:
- **your DuckDNS address**;
- **the institution name** (shown in the app);
- your time zone;
- a **teacher code**: teachers need it to create teacher accounts, so students can't make themselves teachers.
  Press Enter to generate one;
- **optionally** a Gmail address and app password, for "forgot password" emails
  (Google Account → Security → 2-Step Verification → *App passwords*).

It installs everything, gets the HTTPS certificate, starts daily backups, and prints the teacher code.

## Step 4: Build the phone app and publish it

On your computer (needs podman or docker):

```bash
./deploy/build-app.sh myschool.duckdns.org            # makes exist.apk with your address inside
scp -i <your-ssh-key> exist.apk ubuntu@<public-ip>:exist/deploy/downloads/exist.apk
```

Anyone can now download it from **https://myschool.duckdns.org/app.apk**.

## Step 5: Tell teachers

Send teachers the app link and the **teacher code**. Everything else happens in the app:

1. **Teacher:** install → **Create an account** → "I'm a teacher" → teacher code.
2. **Teacher:** **My classes → New class** (subject, group, optional dates) → share the **class code** with that class.
   Add the weekly times in the class's **Schedule** tab (or just tap **Start a class now** whenever teaching).
3. **Students:** install → **Create an account** → "I'm a student" (roll number, class code) → accept the privacy notice →
   register the phone. More classes: **Join a class** with each code.

Attendance is automatic from then on. Teachers see each class's **attendance sheet** in the app or on the website
(https://myschool.duckdns.org, sign in) and can download it as CSV.

---

## Running it

| Task | How |
|---|---|
| See what's happening | `sudo docker compose -f ~/exist/deploy/docker-compose.yml logs -f api` |
| Backups | Daily, in `~/exist/deploy/backups` (last 14 kept). Copy them off the server now and then. |
| Restore a backup | `gunzip -c backups/<file>.sql.gz \| sudo docker compose exec -T db psql -U exist exist` |
| Update Exist | Copy the new `exist-server.tgz`, unpack over the old folder, run `sudo ./deploy/setup.sh` again (settings are kept) |
| New app version | `./deploy/build-app.sh …` then copy `exist.apk` to `deploy/downloads/` as above |
| Block rooted phones | In `deploy/.env` set `ATTESTATION_MODE=strict`, then `sudo docker compose up -d` |
| Change the teacher code | Edit `TEACHER_SIGNUP_CODE` in `deploy/.env`, then `sudo docker compose up -d` (existing teachers are not affected) |

## Good to know

- **Keep `deploy/.env` private and safe.** It holds the keys. If you lose it, existing sign-ins and class records can't be
  decrypted. Back it up together with the database backups.
- **iPhone:** the iPhone app has to be built on a Mac with Xcode, and installing it on others' iPhones needs Apple's developer
  program ($99/year). Android is free.
- **Google Play Store** (optional): a one-time $25 fee. Without it, the APK download link works; Android asks
  users to allow installing from the browser once.
- **Before real use:** do the classroom test in `README.md` (signal range, many phones at once, a closed iPhone app).
