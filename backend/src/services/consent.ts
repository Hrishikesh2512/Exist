// Privacy notice shown before first use (India DPDP Act 2023 style: purpose, data, retention, rights).
// Bump CONSENT_VERSION whenever the text changes in substance; everyone is asked again.
export const CONSENT_VERSION = 1;

export const PRIVACY_NOTICE = {
  version: CONSENT_VERSION,
  title: 'How Exist uses your data',
  sections: [
    {
      heading: 'Why',
      body: 'Exist records class attendance for your institution. It is used only for attendance and academic records.',
    },
    {
      heading: 'What we collect',
      body:
        'Your name, email, roll number and classes; the times your phone checked in to a class; your phone model and a ' +
        'security key created on your phone. Students: nothing else. Exist does not read your location, contacts, photos or GPS. ' +
        'Bluetooth only looks for your teacher\'s phone, and only for your own classes.',
    },
    {
      heading: 'Why Bluetooth and location permission',
      body:
        'Your phone detects the teacher\'s phone over Bluetooth. Android and iPhone treat Bluetooth beacons as "location", ' +
        'so they ask for that permission, but Exist never reads your position.',
    },
    {
      heading: 'Who can see it',
      body: 'You, your teachers (for their own subjects) and your institution\'s administrators. It is never sold or shared with anyone else.',
    },
    {
      heading: 'How long',
      body: 'Attendance records are kept as long as your institution requires for academic records. Phone data is removed when you change phones.',
    },
    {
      heading: 'Your rights',
      body:
        'You can see all your attendance in the app, dispute any record, and withdraw consent at any time in Settings. ' +
        'Withdrawing stops attendance on your phone and asks the administrator to delete your personal data; ' +
        'records your institution must legally keep are anonymised instead.',
    },
  ],
};
