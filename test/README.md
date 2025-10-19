# Test Suite

The test suite exercises the `librarian` command line interface using lightweight
stubs for the application container. The helpers in `test/support` build a
sandboxed environment with fake speakers, dispatchers and pid files so that
commands can run without touching the real filesystem or network services.

Run the tests with:

```
bundle exec ruby -Itest test/librarian_cli_test.rb
```
