//          Copyright Ferdinand Majerech 2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)


/// Utility functions for unittests.
module tharsis.util.testing;


import std.file;


/// The directory to create test files in.
enum testDir = "tharsis-unittest-temp";

/// Create a temporary file with specified contents.
///
/// Params:  name     = Name of the file. This will be the name of the file
///                     created in a temporary test file directory.
///          contents = Contents of the test file.
///
/// Returns: Path to the created test file relative to the current working
///          directory, or null if the file could not be created.
string createTempTestFile(string name, string contents) @trusted
{
    try
    {
        if(!testDir.exists)     { mkdir(testDir); }
        else if(!testDir.isDir) { return null; }

        const fullName = testDir ~ "/" ~ name;
        write(fullName, contents);
        return fullName;
    }
    catch(FileException e)
    {
        return null;
    }
}

/// Delete all temporary test files.
void deleteTempTestFiles() @trusted
{
    rmdirRecurse(testDir);
}
