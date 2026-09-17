# Appventure

Frontend-prototype for lokale arrangementer i Oslo. Prosjektet bruker Vite og er
forberedt for Supabase-autentisering, PostgreSQL og fillagring.

## Lokal utvikling

1. Installer avhengigheter med `npm install`.
2. Kopier `.env.example` til `.env.local`.
3. Fyll inn prosjekt-URL og `publishable key` fra Supabase.
4. Start utviklingsserveren med `npm run dev`.

Prototypen fortsetter å bruke lokale demodata frem til autentisering og API-laget
er koblet til databasen. Den kan derfor også bygges uten Supabase-variablene.

## Databaseskjema

Første migrasjon ligger i `supabase/migrations`. Den oppretter profiler,
arrangementer og invitasjoner, samt tilgangsregler for offentlige og private
arrangementer.

Migrasjonen skal kjøres mot et eget utviklingsprosjekt før frontend kobles til.
Ikke legg service role-nøkler eller andre serverhemmeligheter i `VITE_*`-variabler.
