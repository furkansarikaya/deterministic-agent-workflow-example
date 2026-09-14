package tests

import (
	"errors"
	"testing"

	"example.com/deterministic-agent-workflow/src"
)

func TestRegistryCreatesListsAndCompletesTask(t *testing.T) {
	registry := src.NewTaskRegistry()

	task, err := registry.Create("write workflow")
	if err != nil {
		t.Fatalf("Create() error = %v", err)
	}
	if task.ID != 1 || task.Completed {
		t.Fatalf("Create() task = %#v, want id 1 and incomplete", task)
	}

	tasks := registry.List()
	if len(tasks) != 1 || tasks[0] != task {
		t.Fatalf("List() = %#v, want %#v", tasks, []src.Task{task})
	}

	completed, err := registry.Complete(task.ID)
	if err != nil {
		t.Fatalf("Complete() error = %v", err)
	}
	if !completed.Completed {
		t.Fatalf("Complete() = %#v, want completed task", completed)
	}

	if got := registry.List()[0]; !got.Completed {
		t.Fatalf("List() after Complete() = %#v, want completed task", got)
	}
}

func TestRegistryRejectsBlankTitleWithoutChangingState(t *testing.T) {
	registry := src.NewTaskRegistry()

	_, err := registry.Create("   ")
	if !errors.Is(err, src.ErrInvalidTitle) {
		t.Fatalf("Create(blank) error = %v, want ErrInvalidTitle", err)
	}
	if got := registry.List(); len(got) != 0 {
		t.Fatalf("List() = %#v, want no tasks after rejected input", got)
	}
}

func TestRegistryReportsMissingTask(t *testing.T) {
	registry := src.NewTaskRegistry()

	_, err := registry.Complete(99)
	if !errors.Is(err, src.ErrTaskNotFound) {
		t.Fatalf("Complete(missing) error = %v, want ErrTaskNotFound", err)
	}
}

func TestRegistryFindsTaskWithoutChangingState(t *testing.T) {
	registry := src.NewTaskRegistry()
	created, err := registry.Create("inspect evidence")
	if err != nil {
		t.Fatalf("Create() error = %v", err)
	}

	found, err := registry.Find(created.ID)
	if err != nil {
		t.Fatalf("Find() error = %v", err)
	}
	if found != created {
		t.Fatalf("Find() = %#v, want %#v", found, created)
	}
	if got := registry.List(); len(got) != 1 || got[0] != created {
		t.Fatalf("Find() changed state: %#v", got)
	}
}

func TestRegistryFindReportsMissingTask(t *testing.T) {
	registry := src.NewTaskRegistry()

	_, err := registry.Find(99)
	if !errors.Is(err, src.ErrTaskNotFound) {
		t.Fatalf("Find(missing) error = %v, want ErrTaskNotFound", err)
	}
}
