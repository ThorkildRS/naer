# Appventure

Appventure er en publisert MVP for å finne, opprette og invitere til lokale
arrangementer i Oslo.

Produksjon: <https://appventure.thorkildstray.no>

## Funksjoner

- registrering, e-postbekreftelse, innlogging og glemt passord
- profiler med bilde, bosted og interesser
- offentlige og private arrangementer med kartposisjon og bilde
- egen arrangementsvisning med detaljer, handlinger og direkte delingslenke
- redigering og sletting av egne arrangementer
- venner og interne invitasjoner
- eksterne invitasjonslenker med e-postutsending
- påmelding, avmelding og deltakerliste for offentlige arrangementer
- eksterne påmeldingslenker og lagrede arrangementer på Min side
- valgfri kapasitet, venteliste og automatisk opprykk ved avmelding
- kommentarer på arrangementer med tilgangskontroll og moderering
- kontosletting med opprydding av tilknyttede data og bilder

## Teknologi

- Vite og JavaScript
- Supabase Auth, Postgres, Storage og Edge Functions
- Vercel
- Resend
- Leaflet og OpenStreetMap

## Lokal utvikling

1. Installer avhengigheter med `npm install`.
2. Kopier `.env.example` til `.env.local`.
3. Legg inn Supabase-prosjektets URL og publishable key.
4. Start med `npm run dev`.

```env
VITE_SUPABASE_URL=https://your-project.supabase.co
VITE_SUPABASE_PUBLISHABLE_KEY=your-publishable-key
```

Ikke legg secret key, service role key eller Resend API-nøkler i `VITE_*`.
Variabler med dette prefikset blir tilgjengelige i nettleseren.

## Database

SQL-migrasjonene ligger i `supabase/migrations` og skal kjøres i stigende
filrekkefølge. De oppretter tabeller, funksjoner, Storage-policyer og Row Level
Security for profiler, arrangementer, invitasjoner, venner og påmeldinger.

## Edge Functions

- `send-event-invitation` sender eksterne invitasjoner gjennom Resend.
- `delete-account` sletter bruker, relaterte data og opplastede filer.

Funksjonene krever gyldig bruker-JWT. Leverandørnøkler lagres som Supabase Edge
Function Secrets og skal aldri ligge i Git.

## Produksjonsbygg

```sh
npm run build
```

Vercel bygger automatisk ved push til `main`. Produksjonsmiljøet må inneholde
`VITE_SUPABASE_URL` og `VITE_SUPABASE_PUBLISHABLE_KEY`.
