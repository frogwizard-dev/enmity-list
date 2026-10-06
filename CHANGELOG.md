# EnmityList

## 0.4.0

### Threat lab
- New: `/enmity lab` measures how much threat each of your abilities really makes, from the changes in your threat as you fight. Built for tanks (Sunder Armor, Revenge, Shield Slam, Heroic Strike, Thunder Clap and the rest), it works for any ability.
- Just play normally, auto-attack and all. The lab works it out from all your fighting together: how much threat each point of your damage makes (shown as "damage x 1.30" or so, your stance's multiplier, more with Defiance) and each ability's bonus threat on top. For every ability you see its bonus, the threat from its damage, the total per use, per rage and per second of global cooldown, and how sure the number is (± and how many fights it's from). Your plain swings should come out with no bonus, which is a good check.
- A second method, "Clean samples", measures an ability exactly when it happens to be alone between two threat updates. That's rare once you're swinging, so it fills more slowly; switch between the two at the top of the window.
- Click an ability for its breakdown: the solved numbers, its misses, and its clean measurements by rank, your level, the enemy's level and the outcome.
- Filters: stance (Defensive Stance to start with), your level range, and hits only, misses only or everything. Taunt, Mocking Blow and Challenging Shout are left out of the averages ("sets threat").
- Heroic Strike and Cleave are counted on the swing they replace. Misses, dodges and parries get their own line, so you can see they make no threat.
- Measure alone (no group, no pet): the game doesn't say whose damage is whose. Pulling 2-3 mobs at a time helps your rage.
- In dungeons the game hides threat numbers from add-ons, so the lab pauses there and says so: measure in the open world.
- Measurements are kept per character. `/enmity lab reset` (or the window's button) clears them; `/enmity lab verbose` prints a chat line for each clean measurement.

### Fixes
- Raid marks in the threat list stay visible in instances, where the game hides which mark an enemy has (they vanished there).
- The list keeps updating where the game hides an enemy's name.

### Under the hood
- The threat lead's text, raid marks, names and the FFXIV colours are FrogLib's, shared with FrogPlates and the other Frog Wizard add-ons; settings templates too.

## 0.3.1

### Under the hood
- Shares its options page, its texture and font lists and its threat lead with the other Frog Wizard add-ons (one copy of the code, so a fix reaches them all at once). Nothing changes in how it looks or works.

## 0.3.0

### Threat
- Threat now shows as a gap when there's someone to compare with: "+1.2k" in green is your lead over the next highest while the enemy is on you, "-300" in red is how far behind you are when it's on someone else. It compares you with your party or raid and everyone's pets. Alone, or where the game hides the numbers, it shows your threat % as before. Turn the gap off in the settings to always see the %.
- The same threat shows beside each enemy's nameplate once you're on its threat list, coloured the same way. It can be turned off, and has its own text size. Where the game locks nameplates (some instances), it's left off.

### Fixes
- Names include the surname on Forever, as the game's own frames show them (it showed only the first name).

### Options
- Listed with the rest of Frog Wizard's add-ons: under a "Frog Wizard" heading in the AddOn list, and in its own "Frog Wizard" section of Options > AddOns, whose page lists them all with a button to each one's settings.

## 0.2.2

### Options
- Now listed in the game's Options > AddOns, with a button that opens its settings and a list of its slash commands.

### Fixes
- Fixed a "forbidden object" error that could appear when status-effect text updated in restricted content (for example in combat).
