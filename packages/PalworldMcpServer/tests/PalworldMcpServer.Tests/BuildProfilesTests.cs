using PalCalc.Model;

namespace PalworldMcpServer.Tests;

[TestClass]
public sealed class BuildProfilesTests
{
    [TestMethod]
    public void AttackProfileProducesExplicitGeneticTarget()
    {
        var result = BuildProfiles.Recommend("attack", null, null, null, null);

        Assert.AreEqual("attack", result.Role);
        Assert.AreEqual(100, result.MinimumAttackIv);
        CollectionAssert.AreEquivalent(
            new[] { "Demon God", "Musclehead", "Serenity", "Legend" },
            result.PreferredPassives.ToArray()
        );
    }

    [TestMethod]
    public void BaseWorkerWithoutWorkTypeIsMarkedAmbiguous()
    {
        var result = BuildProfiles.Recommend("base_worker", null, null, null, 90);

        Assert.IsTrue(result.Warnings.Any(warning => warning.Contains("underspecified")));
    }

    [TestMethod]
    public void RanchProfileDoesNotBlindlyRecommendWorkSpeed()
    {
        var result = BuildProfiles.Recommend("ranch_farming", null, null, null, null);

        Assert.IsFalse(result.PreferredPassives.Contains("Artisan"));
        Assert.IsTrue(result.Warnings.Any(warning => warning.Contains("Ranch drops")));
    }

    [TestMethod]
    public void UnknownRoleIsRejected()
    {
        Assert.Throws<ArgumentException>(() =>
            BuildProfiles.Recommend("unknown", null, null, null, null)
        );
    }

    [TestMethod]
    public void PinnedPalCalcDatabaseLoads()
    {
        var database = PalDB.LoadEmbedded();

        Assert.IsFalse(string.IsNullOrWhiteSpace(database.Version));
        Assert.IsTrue(database.Pals.Any());
        Assert.IsTrue(database.StandardPassiveSkills.Any());
    }
}
