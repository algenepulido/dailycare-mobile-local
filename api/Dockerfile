# The API, as it runs on Cloud Run.
#
# Two stages so the thing that ships has no compiler, no module cache and no source in it.
# What is left is one static binary and the certificates it needs to verify Google's.

# The toolchain go.mod asks for. Pinned rather than :latest - a build image that moves on
# its own is a build that is reproducible until the day it is not.
FROM golang:1.26-bookworm AS build
WORKDIR /src

# Dependencies first, so a change to the code does not re-download the world.
COPY go.mod go.sum ./
RUN go mod download

COPY . .
# Static, because the runtime image has no libc to link against. Stripped, because a
# binary that ships its symbol table ships a map of itself.
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /dailycare-api .

# Distroless rather than alpine: no shell, no package manager, nothing to exec into if
# somebody finds a way to run a command. The nonroot variant runs as uid 65532.
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /dailycare-api /dailycare-api

# Cloud Run sets PORT and the process reads it. Stated here so a reader of this file does
# not have to know that.
ENV PORT=8080
EXPOSE 8080

ENTRYPOINT ["/dailycare-api"]
