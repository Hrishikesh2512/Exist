# 7-day class demo

Server: this laptop, published at **https://fedora-laptop.tail37ac76.ts.net** (Tailscale Funnel).
Teacher code: in `.env` (`TEACHER_SIGNUP_CODE`). Database: `exist_demo` (clean; the old test data is untouched in `exist`).

## Tonight / before the first class

1. `! sudo tailscale funnel --bg 8080` (once; stays on after reboots).
2. On **your** phone: install the app from the address above, then **Create an account → I'm a teacher** with the teacher code.
3. **My classes → New class** (e.g. "Data Structures", group "CSE-A"). Note the **class code**.
4. In the class → **Schedule → Add** the weekly times for the demo week (or just use **Start a class now** in class).
5. Send the class message below to the class WhatsApp group.
6. Laptop: plugged in; **Settings → Power → Automatic suspend: off** (at least while plugged in). If the lid will be closed,
   also turn off suspend on lid close. The server restarts by itself after a reboot, once you log in.

## Message for the class group (copy-paste)

> 📲 **Attendance demo this week: please set up before class**
>
> 1. Install the Exist app: https://github.com/Hrishikesh2512/Exist/releases/download/demo-1/Exist.apk
>    (if Android says it can't install, use https://github.com/Hrishikesh2512/Exist/releases/download/demo-1/Exist-older-phones.apk)
>    Android will ask to allow installing from your browser: allow it once.
> 2. Open it → **Create an account** → *I'm a student* → your name, college email, roll number, a password,
>    and class code **XXXXXXXX**.
> 3. Accept the privacy notice → allow **Bluetooth** (and Location if asked; it never reads your GPS) and **Notifications**
>    → **Register this phone** → allow running in the background.
>
> That's it. Keep Bluetooth on during class; attendance is taken automatically, three times per class.
> You can see your attendance in the app (Attendance tab).

## During class (your phone)

- The class starts by itself at its time, or tap **Start a class now**. Keep the phone in the room; iPhone: keep the app open.
- Tap **Open** to see names ticking in. Try **Surprise check** once; phones check in again by themselves.
- Someone's phone not working? Tap their name → mark them yourself.
- After class: **Results**, and each class's **Attendance sheet** (My classes → class → Attendance sheet). Tap a cell to change it.

## Suggested 7 days

| Day | Show |
|---|---|
| 1 | Everyone installs and joins. Run a short class; show names appearing and the three checks. |
| 2 | A normal class that starts automatically; show the attendance sheet and each student's own sheet. |
| 3 | Surprise check, pause, a student "without phone" marked by hand, a dispute from a student. |
| 4 | Calendar: add a "no class" day and a test; students see it. Students add their own calendar entries. |
| 5 | Offline: teacher phone without internet; it syncs afterwards. |
| 6 | Late teacher / cancelled or moved class; students are notified. |
| 7 | Totals and the CSV register from the website (sign in at the address above). Collect feedback. |

## If something goes wrong

| Problem | Fix |
|---|---|
| App can't connect | Laptop on and online? `curl -s localhost:8080/health` · `tailscale funnel status` |
| Server down | `./deploy/laptop-server.sh` (restarts it) |
| A student can't install | Use the `app-32.apk` link |
| A student's phone doesn't check in | Bluetooth on? Check-ins can also be done with **Check in now** or the classroom QR (website → Run without phone) |
| Backups | Daily at 21:00 in `~/.local/share/exist/backups` |

After the demo:
- Stop the public address: `tailscale funnel --https=443 off`
- Let the laptop sleep again when the lid closes: `sudo rm /etc/systemd/logind.conf.d/exist-keep-awake.conf && sudo systemctl kill -s HUP systemd-logind`
- Let it sleep when idle again: `gsettings reset org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type`
