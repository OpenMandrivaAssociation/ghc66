-- Alex 2.1.0 only needs removeFile. Base's System.Directory was not
-- built: System/Time.hsc was never run through hsc2hs, so the real
-- module still cannot see ClockTime. This is the POSIX unlink that
-- removeFile is, and it is on alex's -i path ahead of base.
module System.Directory (removeFile) where

import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt)

removeFile :: FilePath -> IO ()
removeFile path = withCString path $ \s -> do
  r <- c_unlink s
  if r == 0
    then return ()
    else ioError (userError ("removeFile: cannot unlink " ++ path))

foreign import ccall unsafe "unlink" c_unlink :: CString -> IO CInt
