# TaskFlow API

A lightweight REST API for managing tasks and projects. Built with Node.js and Express.

## Features
- Create, read, update, delete tasks
- Assign tasks to users
- Priority levels: low, medium, high, urgent
- Project grouping and tagging

## Getting Started

```bash
npm install
npm start
```

API runs on `http://localhost:3000`.

## Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | /tasks | List all tasks |
| POST | /tasks | Create a task |
| GET | /tasks/:id | Get a task |
| PUT | /tasks/:id | Update a task |
| DELETE | /tasks/:id | Delete a task |
| GET | /projects | List projects |
| POST | /projects | Create a project |
