# Exist — Rulebook & Features

I built Exist so that attendance takes itself: bring your phone to class, keep Bluetooth on, and you are marked — three times per class, with no roll call and no proxies. This page is the rulebook for students and teachers, and the list of what the app can do.

## How it works

The teacher's phone quietly broadcasts over Bluetooth during class. Your phone recognises it — but only for the classes you have joined — and checks you in on its own, signed with a key that lives inside your phone's security chip and can never be copied. Nobody taps anything.

1. **Teachers** create their classes in the app and share a class code.
2. **Students** create an account, join with that code and register their phone once.
3. **In class**, attendance is checked three times: at the start, at a secret random moment in the middle, and at the end.
4. **Afterwards**, everyone sees the result: teachers see the whole class's attendance sheet, students see their own.

## Rules for students

1. **One account, one phone.** Your account works only on the phone you registered. Moving to a new phone needs your teacher's approval, or happens by itself after 48 hours.
2. **Bring your own phone to class, with Bluetooth on.** That is all you have to do. Attendance is taken automatically; you never need to open the app.
3. **Stay for the whole class.** You are checked at the start, at a secret moment in the middle, and at the end. Missing the middle or the end shows on your sheet.
4. **Only your own classes count.** Your phone checks in only to classes you joined with the teacher's code.
5. **No proxies.** Your check-in is signed by a key inside your phone that cannot be copied. Carrying a friend's phone, forwarding a code, or checking in from outside the room does not work, and surprise checks can happen at any time.
6. **If your phone fails, tell your teacher in class.** They can mark you present by hand, a few times per term.
7. **Found a mistake? Report it within 3 days.** Tap the entry on your attendance sheet and tell your teacher what happened.
8. **Leave (medical, on duty) goes through your teacher**, who records it so those classes count as excused.

## Rules for teachers

1. **Create a teacher account with the teacher code** I share with teachers. Students cannot become teachers without it.
2. **Create one class per subject and group** (for example Data Structures · CSE-A) and share its class code only with that group.
3. **Keep your phone in the classroom during class, with Bluetooth on.** On Android it can stay in your pocket; on iPhone keep Exist open on screen.
4. **Start and end classes properly.** Timetabled classes start by themselves; you can also tap Start a class now. If you arrive late, students are not marked late for it.
5. **Every change you make is recorded.** You can change any entry on the attendance sheet, but always with a reason, and the change is kept in the log.
6. **Use "present without phone" only for students you saw in class.** It is limited per term on purpose.
7. **Answer disputes within the week**, and approve a student's new phone only when you know it is really them.
8. **Share the co-teacher code only with teachers** who teach the class with you.

## How attendance is decided

Every class has three checks. The start check is open for the first 10 minutes after the teacher starts, the middle check happens at a random time nobody knows in advance, and the end check covers the last 10 minutes.

| Start | Middle | End | Result | Counts as |
| --- | --- | --- | --- | --- |
| ✓ | ✓ | ✓ | Present | 100% |
| ✗ | ✓ | ✓ | Late | 100% (teacher can change) |
| ✓ | ✓ | ✗ | Left early | 50% (teacher can change) |
| ✓ | ✗ | ✓ | Needs review | 0% until the teacher decides |
| two or more ✗ | | | Absent | 0% |
| leave recorded | | | Excused | not counted at all |

A check that could not happen (teacher's phone off, class paused, nobody in the room) never counts against anyone. The required attendance is 75%; I send a warning when a subject drops below it.

## Features for students

| Feature | What it does |
| --- | --- |
| Automatic check-in | Your phone checks you in by itself, even with the app closed, only for your own classes |
| Join a class | Enter the class code from your teacher; add as many classes as you study |
| My attendance | Your total for all classes, each class's %, and a warning below 75% |
| My attendance sheet | Every class held, your result and why (e.g. missed the middle check) |
| Report a mistake | Tap a wrong entry to tell your teacher, within 3 days |
| Calendar | Your classes, holidays and tests in one month view |
| My own calendar entries | Add study plans or reminders; only you can see them |
| Add to Google / Apple Calendar | A private link that keeps your calendar app up to date |
| Alerts | Class cancelled or moved, teacher late, marked absent, low attendance |
| Check in now | A button for the rare case your phone missed a check |
| Classroom QR code | Backup when the teacher's phone is not available |
| Your account | Change password, forgot password, read the privacy notice, delete your account |

## Features for teachers

| Feature | What it does |
| --- | --- |
| My classes | Create a class (subject, group, optional start and end dates), get its class code and co-teacher code |
| Start a class now | Take a class any time, with or without a timetable, even without internet |
| Weekly timetable | Classes start by themselves at their time |
| Live class | Names tick in as students arrive; pause, surprise check, +10 min, end early |
| Mark by hand | Tap a student during class (phone dead, left without permission) |
| Attendance sheet | Whole class × every date with %, tap any cell to change it, download as CSV |
| Students | Everyone's %, full record per student, record leave, remove from class |
| Special days | No class, test or event for a class; students are told automatically |
| Move or cancel a class | Students get the new time or the reason |
| Disputes | Accept or reject when a student reports a mistake |
| New phones | Approve a student's new phone early |
| Password help | Reset a student's forgotten password |
| Settings per class | Auto-start, number of middle checks, how late and left early count |
| Works offline | The class runs fully on your phone and uploads when internet is back |
| Website | Attendance sheets and CSV on a computer; run a class from the projector with a QR code if your phone is unavailable |

## Privacy and security

I collect only what attendance needs: your name, email, roll number, your classes, the times your phone checked in, and your phone's model. Nothing else.

- **No location tracking.** Some phones ask for location permission because of how Bluetooth works, but Exist never reads your GPS position.
- **Bluetooth only listens for your own classes.** It ignores every other class and every other device.
- **Who sees your attendance:** you, and the teachers of that class. Nobody else, and it is never sold or shared.
- **Your phone is your ID.** Check-ins are signed by a key locked inside your phone. A modified or rooted phone is flagged to your teacher.
- **You are in control.** You can read the privacy notice any time, and delete your account in Settings. Your name, email and phone are then erased; the class register keeps only an anonymous entry.
- **Your password** can be changed any time; changing it signs you out on every other device. After 8 wrong tries the account locks for 15 minutes.

## When something goes wrong

| Problem | What to do |
| --- | --- |
| The app won't install | Allow installing from WhatsApp or the browser when asked; on older phones use the "older phones" version |
| My phone didn't check in | Check Bluetooth is on and tap Check in now; if it still fails, tell your teacher in class |
| "Not in this class" | You haven't joined that class: ask the teacher for its class code |
| I got a new phone | Register it; your teacher approves it, or it switches automatically after 48 hours |
| I forgot my password | Tap Forgot password, or ask your teacher to reset it |
| My attendance looks wrong | Tap the entry in your attendance sheet and tell your teacher within 3 days |
| The teacher's phone isn't working | The teacher can run the class from the website with a QR code you scan in the app |

Still stuck? Message me, and I'll sort it out.
