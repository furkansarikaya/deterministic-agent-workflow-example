// Package src contains the deliberately small application used by this repository.
package src

import (
	"errors"
	"strings"
)

var (
	ErrInvalidTitle = errors.New("task title must not be blank")
	ErrTaskNotFound = errors.New("task not found")
)

// Task is the immutable view returned by the registry.
type Task struct {
	ID        int
	Title     string
	Completed bool
}

// TaskRegistry stores tasks in process memory for the workflow example.
type TaskRegistry struct {
	nextID int
	tasks  []Task
}

func NewTaskRegistry() *TaskRegistry {
	return &TaskRegistry{nextID: 1, tasks: []Task{}}
}

func (r *TaskRegistry) Create(title string) (Task, error) {
	cleanTitle := strings.TrimSpace(title)
	if cleanTitle == "" {
		return Task{}, ErrInvalidTitle
	}

	task := Task{ID: r.nextID, Title: cleanTitle}
	r.nextID++
	r.tasks = append(r.tasks, task)
	return task, nil
}

func (r *TaskRegistry) List() []Task {
	return append([]Task(nil), r.tasks...)
}

func (r *TaskRegistry) Complete(id int) (Task, error) {
	for index, task := range r.tasks {
		if task.ID != id {
			continue
		}
		completed := Task{ID: task.ID, Title: task.Title, Completed: true}
		r.tasks[index] = completed
		return completed, nil
	}
	return Task{}, ErrTaskNotFound
}
