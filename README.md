# NAME

Test::HTTP::Scenario - Deterministic record/replay of HTTP interactions for test suites

# SYNOPSIS

    use Test::Most;
    use Test::HTTP::Scenario qw(with_http_scenario);

    with_http_scenario(
        name    => 'get_user_basic',
        file    => 't/fixtures/get_user_basic.yaml',
        mode    => 'replay',
        adapter => 'LWP',
        sub {
            my $user = $client->get_user(42);
            cmp_deeply($user, superhashof({ id => 42 }));
        },
    );

# DESCRIPTION

Test::HTTP::Scenario provides a deterministic record/replay mechanism
for HTTP-based test suites. It allows you to capture real HTTP
interactions once (record mode) and replay them later without network
access (replay mode). This makes API client tests fast, hermetic, and
fully deterministic.

Adapters provide the glue to specific HTTP client libraries such as
LWP. Serializers control how fixtures are stored
on disk.

# MODES

## record

Real HTTP requests are executed. Each request/response pair is
normalized and appended to the fixture. The fixture file is written at
the end of `run()`.

## replay

No real HTTP requests are made. Requests are matched against the
fixture in order, and responses are reconstructed from stored data.

# STRICT MODE

If `strict => 1` is enabled, replay mode requires that all
recorded interactions are consumed. If the callback returns early,
`run()` croaks with a strict-mode error.

# DIFFING

If `diffing => 1` (default), mismatched requests produce a
detailed diff showing expected and actual method, URI, and normalized
request structures.

# ADAPTERS

Adapters implement:

- request/response normalization
- response reconstruction
- temporary monkey-patching of the HTTP client library

Available adapters:

- LWP

You may also supply a custom adapter object.

# SERIALIZERS

Serializers implement encoding and decoding of fixture files.

Available serializers:

- YAML (default)
- JSON

# USING RECORD AND REPLAY IN REAL-WORLD APPLICATIONS

This section describes the recommended workflow for using
`Test::HTTP::Scenario` in a real-world test suite. The goal is to
capture real HTTP traffic once (record mode) and then replay it
deterministically in all subsequent test runs (replay mode).

## Overview

Record/replay is designed for API client libraries that normally make
live HTTP requests. In record mode, the module performs real network
calls and stores normalized request/response pairs in a fixture file.
In replay mode, the module prevents all network access and returns
synthetic responses reconstructed from the fixture.

This allows your test suite to:

- run without network access
- avoid flakiness caused by external services
- run quickly and deterministically in CI
- capture complex multi-step API flows once and reuse them

## Typical Workflow

### Step 1: Write your test using `with_http_scenario`

    use Test::Most;
    use Test::HTTP::Scenario qw(with_http_scenario);

    with_http_scenario(
        name    => 'get_user_flow',
        file    => 't/fixtures/get_user_flow.yaml',
        mode    => $ENV{SCENARIO_MODE} || 'replay',
        adapter => 'LWP',
        sub {
            my $user = MyAPI->new->get_user(42);
            is $user->{id}, 42, 'user id matches';
        },
    );

### Step 2: Run the test suite in record mode

    $ SCENARIO_MODE=record prove -l t/get_user_flow.t

This performs real HTTP requests and writes the fixture file:

    t/fixtures/get_user_flow.yaml

### Step 3: Commit the fixture file to version control

The fixture becomes part of your test assets. It should be treated like
any other test data file.

### Step 4: Run the test suite normally (replay mode)

    $ prove -l t

Replay mode:

- loads the fixture
- intercepts all HTTP requests
- matches them against the recorded interactions
- returns synthetic responses

No network access is required.

## Updating Fixtures

If the API changes or you need to refresh the recorded data, simply
delete the fixture file and re-run the test in record mode:

    $ rm t/fixtures/get_user_flow.yaml
    $ SCENARIO_MODE=record prove -l t/get_user_flow.t

## Example: Multi-Step API Flow

Record mode captures each request in order:

    with_http_scenario(
        name    => 'create_and_fetch',
        file    => 't/fixtures/create_and_fetch.yaml',
        mode    => $ENV{SCENARIO_MODE} || 'replay',
        adapter => 'LWP',
        sub {
            my $api = MyAPI->new;

            my $id = $api->create_user({ name => 'Alice' });
            my $user = $api->get_user($id);

            is $user->{name}, 'Alice';
        },
    );

Replay mode enforces the same sequence, ensuring your client behaves
correctly across multiple calls.

## Notes

- Replay mode never performs real HTTP requests.
- Strict mode can be enabled to ensure all interactions are consumed.
- Diffing mode provides detailed diagnostics when a request does not match.
- Fixtures are stable across platforms and Perl versions.

## API Specification

### Input (Params::Validate::Strict)

    name      => Str
    file      => Str
    mode      => 'record' | 'replay'
    adapter   => Str | Object
    serializer => Str (optional)
    diffing   => Bool (optional)
    strict    => Bool (optional)
    CODE      => Coderef

### Output (Returns::Set)

    any value returned by the supplied coderef

# METHODS

## new

Construct a new scenario object.

### Purpose

Initializes a scenario with a name, fixture file, mode, adapter, and
serializer. Loads adapter and serializer classes and binds the adapter
to the scenario.

### Arguments

- name (Str, required)

    Scenario name.

- file (Str, required)

    Path to the fixture file.

- mode (Str, required)

    Either `record` or `replay`.

- adapter (Str|Object, required)

    Adapter name such as `LWP` or an adapter object.

- serializer (Str, optional)

    Serializer name, default `YAML`.

- diffing (Bool, optional)

    Enable or disable diffing, default true.

- strict (Bool, optional)

    Enable or disable strict behaviour, default false.

### Returns

A new [Test::HTTP::Scenario](https://metacpan.org/pod/Test%3A%3AHTTP%3A%3AScenario) object.

### Side Effects

Loads adapter and serializer classes dynamically. Binds the adapter to
the scenario.

### Notes

The adapter object persists across calls to `run()`.

## run

Execute a coderef under scenario control.

### Purpose

Installs adapter hooks, loads fixtures in replay mode, executes the
callback, and saves fixtures in record mode. Ensures uninstall and
save always occur.

### Arguments

- CODE (Coderef, required)

    The code to execute while the adapter hooks are active.

### Returns

Whatever the coderef returns, preserving list, scalar, or void context.

### Side Effects

- Installs adapter hooks.
- Loads fixtures in replay mode.
- Saves fixtures in record mode.
- Uninstalls adapter hooks at scope exit.

### Notes

Exceptions propagate naturally. Strict mode enforces full consumption
of recorded interactions.

## with\_http\_scenario

Convenience wrapper for constructing and running a scenario.

### Purpose

Creates a scenario object from key/value arguments and immediately
executes `run()` with the supplied coderef.

### Arguments

Key/value pairs identical to `new`, followed by a coderef.

### Returns

Whatever the coderef returns.

### Side Effects

Constructs a scenario and installs adapter hooks during execution.

### Notes

The final argument must be a coderef.

## handle\_request

Handle a single HTTP request in record or replay mode.

### Purpose

In record mode, performs the real HTTP request and stores the
normalized request and response. In replay mode, matches the incoming
request against stored interactions and returns a synthetic response.

### Arguments

- req (Object)

    Adapter-specific request object.

- do\_real (Coderef)

    Coderef that performs the real HTTP request.

### Returns

- In record mode: the real HTTP::Response.
- In replay mode: a reconstructed HTTP::Response.

### Side Effects

- Appends interactions in record mode.
- Advances the internal cursor in replay mode.

### Notes

Matching is currently based on method and URI only. Diffing mode
produces detailed mismatch diagnostics.

## \_load\_if\_needed

Load fixture interactions from disk if required.

### Purpose

Populate the scenario's interactions array when in replay mode and the
fixture has not yet been loaded.

### Arguments

None.

### Returns

Nothing.

### Side Effects

Reads the fixture file from disk if it exists.

### Notes

Idempotent. Does nothing if already loaded or not in replay mode.

## \_save\_if\_needed

Write fixture interactions to disk if required.

### Purpose

Serialize and write recorded interactions to the fixture file at the
end of a record-mode run.

### Arguments

None.

### Returns

Nothing.

### Side Effects

Writes to the fixture file on disk.

### Notes

Only active in record mode.

## \_normalize\_request

Normalize an adapter-specific request object.

### Purpose

Convert a request object into a stable, serializable hash structure.

### Arguments

- req (Object)

    Adapter-specific request object.

### Returns

Hashref representing the normalized request.

### Side Effects

None.

### Notes

Delegates to the adapter.

## \_normalize\_response

Normalize an adapter-specific response object.

### Purpose

Convert a response object into a stable, serializable hash structure.

### Arguments

- res (Object)

    Adapter-specific response object.

### Returns

Hashref representing the normalized response.

### Side Effects

None.

### Notes

Delegates to the adapter.

## \_denormalize\_response

Reconstruct an adapter-specific response object.

### Purpose

Convert a stored response hash back into a real HTTP::Response object.

### Arguments

- hash (HashRef)

    Normalized response structure.

### Returns

A real HTTP::Response object.

### Side Effects

None.

### Notes

Delegates to the adapter.

## \_requests\_match

Compare two normalized request hashes.

### Purpose

Determine whether an incoming request matches the expected request in
the fixture.

### Arguments

- exp (HashRef)

    Expected normalized request.

- got (HashRef)

    Actual normalized request.

### Returns

Boolean true if method and URI match.

### Side Effects

None.

### Notes

Header and body matching may be added later.

## \_request\_diff\_string

Produce a human-readable diff for mismatched requests.

### Purpose

Generate a diagnostic string showing differences between expected and
actual requests.

### Arguments

- exp (HashRef)

    Expected request.

- got (HashRef)

    Actual request.

- idx (Int)

    Interaction index.

### Returns

A multi-line string describing the mismatch.

### Side Effects

None.

### Notes

Used only when diffing is enabled.
