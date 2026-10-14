package syncjob

import (
	"context"
	"time"
)

// Seed fills s with demo jobs and past runs.
// ponytail: demo data until jobs are persisted
func Seed(s *Store, f *Fake, now time.Time) {
	jobs := []Job{
		{Name: "Mobile bugs → ADO", JiraKey: "SE", ADOProject: "kai-mobile", Type: Manual,
			Mappings: SmartDefaults(), Filters: DefaultFilters()},
		{Name: "Web platform stories", JiraKey: "WEB", ADOProject: "kai-web", Type: Scheduler,
			Mappings: SmartDefaults()[:4], Filters: Filters{AreaPath: `kai-web\Platform`, Iteration: `kai-web\Sprint 42`}},
		{Name: "Support escalations", JiraKey: "SUP", ADOProject: "kai-support", Type: Webhook,
			Mappings: SmartDefaults()[:3], Filters: withUsers(DefaultFilters(), UserPair{Jira: "support.lead@kai.example", ADOEmail: "support.lead@kai.example"})},
	}
	clock := f.Now
	defer func() { f.Now = clock }()
	for i, j := range jobs {
		id := s.AddJob(j)
		for k := 2 - i; k >= 0; k-- { // oldest first; the store keeps newest first
			at := now.Add(-time.Duration(k*7+i*3+1) * time.Hour)
			f.Now = func() time.Time { return at }
			r := f.Sync(context.Background(), Connection{}, *s.Job(id))
			r.Duration = time.Duration(800+k*450) * time.Millisecond
			s.AddRun(r)
		}
	}
	s.SetStatus(3, Paused)
}

func withUsers(f Filters, u ...UserPair) Filters {
	f.Users = u
	return f
}
