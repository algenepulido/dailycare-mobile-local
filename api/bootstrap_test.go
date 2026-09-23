package main

import "testing"

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
