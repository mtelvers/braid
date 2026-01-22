@0xb8e7a3f2c1d4e5f6;

interface BraidService {
  # Run health checks across commits
  run @0 (
    repoUrl :Text,
    numCommits :UInt32,
    forkJobs :UInt32,
    os :Text,
    osFamily :Text,
    osDistribution :Text,
    osVersion :Text
  ) -> (
    manifestJson :Text
  );

  # Merge test on stacked repositories
  mergeTest @1 (
    repoUrls :List(Text),
    forkJobs :UInt32,
    os :Text,
    osFamily :Text,
    osDistribution :Text,
    osVersion :Text
  ) -> (
    manifestJson :Text
  );
}
