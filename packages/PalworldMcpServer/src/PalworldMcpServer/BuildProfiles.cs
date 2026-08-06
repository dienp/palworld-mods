namespace PalworldMcpServer;

public sealed record BuildRecommendation(
    string Role,
    string? WorkType,
    IReadOnlyList<string> RequiredPassives,
    IReadOnlyList<string> PreferredPassives,
    int MinimumHpIv,
    int MinimumAttackIv,
    int MinimumDefenseIv,
    IReadOnlyList<string> Assumptions,
    IReadOnlyList<string> Warnings
);

public static class BuildProfiles
{
    public static BuildRecommendation Recommend(
        string role,
        string? workType,
        IReadOnlyList<string>? required,
        IReadOnlyList<string>? preferred,
        int? minimumIv
    )
    {
        var normalized = role.Trim().ToLowerInvariant();
        var requiredPassives = required?.Distinct(StringComparer.OrdinalIgnoreCase).ToList() ?? [];
        var preferredPassives = preferred?.Distinct(StringComparer.OrdinalIgnoreCase).ToList() ?? [];
        var assumptions = new List<string>();
        var warnings = new List<string>();
        var hp = 0;
        var attack = 0;
        var defense = 0;

        switch (normalized)
        {
            case "attack":
                preferredPassives.AddRange(["Demon God", "Musclehead", "Serenity", "Legend"]);
                attack = minimumIv ?? 100;
                assumptions.Add("General direct-combat attack build; no mounted, partner-skill, or single-element specialization was requested.");
                break;
            case "defense":
                preferredPassives.AddRange(["Diamond Body", "Burly Body", "Legend", "Serenity"]);
                hp = defense = minimumIv ?? 100;
                assumptions.Add("General survivability build; no raid-tank or player-buff specialization was requested.");
                break;
            case "combat_balanced":
                preferredPassives.AddRange(["Demon God", "Diamond Body", "Serenity", "Legend"]);
                hp = attack = defense = minimumIv ?? 90;
                break;
            case "transport":
                preferredPassives.AddRange(["Swift", "Runner", "Legend", "Workaholic"]);
                assumptions.Add("Prioritizes movement and uptime; actual transport performance also depends on species suitability and transport speed.");
                break;
            case "base_worker":
                preferredPassives.AddRange(["Artisan", "Work Slave", "Serious", "Nocturnal"]);
                if (string.IsNullOrWhiteSpace(workType))
                {
                    warnings.Add("Base worker is underspecified. Provide a work type such as handiwork, mining, planting, or medicine production.");
                }
                break;
            case "ranch_farming":
                preferredPassives.AddRange(["Nocturnal", "Workaholic", "Diet Lover"]);
                warnings.Add("Work Speed does not necessarily increase Ranch drops. The final profile must be checked against the target species' partner-skill mechanics.");
                break;
            case "custom":
                if (requiredPassives.Count == 0 && preferredPassives.Count == 0)
                {
                    warnings.Add("A custom build needs required or preferred passives.");
                }
                break;
            default:
                throw new ArgumentException($"Unknown role '{role}'.");
        }

        return new BuildRecommendation(
            normalized,
            workType,
            requiredPassives.Distinct(StringComparer.OrdinalIgnoreCase).ToList(),
            preferredPassives.Distinct(StringComparer.OrdinalIgnoreCase).Take(4).ToList(),
            hp,
            attack,
            defense,
            assumptions,
            warnings
        );
    }
}
