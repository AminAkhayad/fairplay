// Fill in your own Supabase project here.
//   url:     Project Settings → Data API → Project URL
//   anonKey: Project Settings → API Keys → Publishable key (starts with sb_publishable_)
//            (older projects call this the "anon public" key – that works too)
//
// The publishable key is meant to be used in the browser: what it can do is
// limited by the security rules in supabase/schema.sql.
// NEVER put the Secret key (sb_secret_...) or the service_role key here.
window.FAIRPLAY_CONFIG = {
  url: 'https://ruxglpaboaytjykueruu.supabase.co',
  anonKey: 'sb_publishable_DF1PUBsEW54NYlGVYkY_Jw_1LM_-ClV',
  // Public key for push notifications (safe to share). The matching private key is
  // a secret of the Edge Function "notify" in Supabase – never put it here.
  vapidPublicKey: 'BNd3RqfFIwZH-uRPgXfNIK_BQqBKCu6a-iY0T3JoVmVRkzDByu1dh3wBMuSgmvqiY_iIkgK2lQE58434QrOW_a4',
};
