/* Distributed under the Boost Software License, Version 1.0.
 *    (See accompanying file LICENSE_1_0.txt or copy at
 *          http://www.boost.org/LICENSE_1_0.txt)
 */

/* Replace line endings with LF
 */

import std.file, std.path, std.string;

void main(string[] args)
{
    foreach (f; args[1 .. $])
        if (f.exists)
            f.write(f.readText.lineSplitter.join('\n'));
}

