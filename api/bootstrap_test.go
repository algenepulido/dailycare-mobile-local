package main

import (
	"context"
	"strings"
	"testing"
)

// The flag that says which residents a caregiver is responsible for.
//
// It takes uuids because an assignment is what lets one named person read one named
// resident's record, and a typo that silently became a name would assign them to nobody
// and look like it worked.
func TestTheResidentFlagRefusesAnythingThatIsNotAnId(t *testing.T) {
	var list residentList

	if err := list.Set("44444444-4444-4444-4444-444444444444"); err != nil {
		t.Fatalf("a real id was refused: %v", err)
	}
	if len(list) != 1 {
		t.Fatalf("wanted one resident, got %d", len(list))
	}

	for _, bad := range []string{"Cathy", "", "4444", "44444444-4444-4444-4444-44444444444z"} {
		if err := list.Set(bad); err == nil {
			t.Errorf("%q was accepted as a resident id", bad)
		}
	}
	if len(list) != 1 {
		t.Fatalf("something that was refused was kept anyway: %v", list)
	}
}

// A care manager named alongside a resident.
//
// The two cannot both be meant: a care manager reads every resident in their facility
// because of who they are, so an assignment adds no access and does add their name to that
// resident's card as one of the people looking after them. The deployed job carries a
// resident in its environment, so this combination is what you get by asking it for a care
// manager and changing nothing else - and it used to be accepted, write the assignment, and
// then print that assignments were not needed here.
//
// It returns before anything is opened, so this needs no database.
func TestACareManagerCannotBeAssignedToAResident(t *testing.T) {
	err := bootstrap(context.Background(), []string{
		"-role", "care_manager",
		"-facility", "11111111-1111-1111-1111-111111111111",
		"-email", "noor@cedar.test",
		"-name", "Noor Haddad",
		"-resident", "44444444-4444-4444-4444-444444444444",
	})
	if err == nil {
		t.Fatal("a care manager was accepted with a resident to be assigned to")
	}
	if !strings.Contains(err.Error(), "takes no -resident") {
		t.Fatalf("refused for the wrong reason: %v", err)
	}
}

// The same flags without the resident have to get past this check, or the test above is
// passing because something else is wrong with them.
func TestACareManagerWithNoResidentGetsPastTheCheck(t *testing.T) {
	err := bootstrap(context.Background(), []string{
		"-role", "care_manager",
		"-facility", "11111111-1111-1111-1111-111111111111",
		"-email", "noor@cedar.test",
		"-name", "Noor Haddad",
	})
	if err != nil && strings.Contains(err.Error(), "takes no -resident") {
		t.Fatalf("refused for naming a resident it was not given: %v", err)
	}
}
