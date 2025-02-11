{-| General purpose utilities

    The names in this module clash heavily with the Haskell Prelude, so I
    recommend the following import scheme:

> import Pipes
> import qualified Pipes.Prelude as P  -- or use any other qualifier you prefer

    Note that 'String'-based 'IO' is inefficient.  The 'String'-based utilities
    in this module exist only for simple demonstrations without incurring a
    dependency on the @text@ package.

    Also, 'stdinLn' and 'stdoutLn' remove and add newlines, respectively.  This
    behavior is intended to simplify examples.  The corresponding @stdin@ and
    @stdout@ utilities from @pipes-bytestring@ and @pipes-text@ preserve
    newlines.
-}

{-# LANGUAGE RankNTypes, Trustworthy #-}
{-# OPTIONS_GHC -fno-warn-unused-do-bind #-}

module Pipes.Prelude (
    -- * Producers
    -- $producers
      stdinLn
    , readLn
    , fromHandle
    , repeatM
    , replicateM
    , unfoldr

    -- * Consumers
    -- $consumers
    , stdoutLn
    , stdoutLn'
    , mapM_
    , print
    , toHandle
    , drain

    -- * Pipes
    -- $pipes
    , map
    , mapM
    , sequence
    , mapFoldable
    , filter
    , filterM
    , take
    , takeWhile
    , takeWhile'
    , drop
    , dropWhile
    , concat
    , elemIndices
    , findIndices
    , scan
    , scanM
    , chain
    , read
    , show
    , seq

    -- *ListT
    , loop

    -- * Folds
    -- $folds
    , fold
    , fold'
    , foldM
    , foldM'
    , all
    , any
    , and
    , or
    , elem
    , notElem
    , find
    , findIndex
    , head
    , index
    , last
    , length
    , maximum
    , minimum
    , null
    , sum
    , product
    , toList
    , toListM
    , toListM'

    -- * Zips
    , zip
    , zipWith

    -- * Utilities
    , tee
    , generalize
    ) where

import Control.Exception (throwIO, try)
import Control.Monad (liftM, when, unless)
import Control.Monad.Trans.State.Strict (get, put)
import Data.Functor.Identity (Identity, runIdentity)
import Foreign.C.Error (Errno(Errno), ePIPE)
import GHC.Exts (build)
import Pipes
import Pipes.Core
import Pipes.Internal
import Pipes.Lift (evalStateP)
import qualified GHC.IO.Exception as G
import qualified System.IO as IO
import qualified Prelude
import Prelude hiding (
      all
    , and
    , any
    , concat
    , drop
    , dropWhile
    , elem
    , filter
    , head
    , last
    , length
    , map
    , mapM
    , mapM_
    , maximum
    , minimum
    , notElem
    , null
    , or
    , print
    , product
    , read
    , readLn
    , sequence
    , show
    , seq
    , sum
    , take
    , takeWhile
    , zip
    , zipWith
    )

{- $producers
    Use 'for' loops to iterate over 'Producer's whenever you want to perform the
    same action for every element:

> -- Echo all lines from standard input to standard output
> runEffect $ for P.stdinLn $ \str -> do
>     lift $ putStrLn str

    ... or more concisely:

>>> runEffect $ for P.stdinLn (lift . putStrLn)
Test<Enter>
Test
ABC<Enter>
ABC
...

-}

{-| Read 'String's from 'IO.stdin' using 'getLine'

    Terminates on end of input
-}
stdinLn :: MonadIO m => Producer' String m ()
stdinLn = fromHandle IO.stdin
{-# INLINABLE stdinLn #-}

-- | 'read' values from 'IO.stdin', ignoring failed parses
readLn :: (MonadIO m, Read a) => Producer' a m ()
readLn = stdinLn >-> read
{-# INLINABLE readLn #-}

{-| Read 'String's from a 'IO.Handle' using 'IO.hGetLine'

    Terminates on end of input
-}
fromHandle :: MonadIO m => IO.Handle -> Producer' String m ()
fromHandle h = go
  where
    go = do
        eof <- liftIO $ IO.hIsEOF h
        unless eof $ do
            str <- liftIO $ IO.hGetLine h
            yield str
            go
{-# INLINABLE fromHandle #-}

-- | Repeat a monadic action indefinitely, 'yield'ing each result
repeatM :: Monad m => m a -> Producer' a m r
repeatM m = lift m >~ cat
{-# INLINABLE [1] repeatM #-}

{-# RULES
  "repeatM m >-> p" forall m p . repeatM m >-> p = lift m >~ p
  #-}

{-| Repeat a monadic action a fixed number of times, 'yield'ing each result

> replicateM  0      x = return ()
>
> replicateM (m + n) x = replicateM m x >> replicateM n x  -- 0 <= {m,n}
-}
replicateM :: Monad m => Int -> m a -> Producer' a m ()
replicateM n m = lift m >~ take n
{-# INLINABLE replicateM #-}

{- $consumers
    Feed a 'Consumer' the same value repeatedly using ('>~'):

>>> runEffect $ lift getLine >~ P.stdoutLn
Test<Enter>
Test
ABC<Enter>
ABC
...

-}

{-| Write 'String's to 'IO.stdout' using 'putStrLn'

    Unlike 'toHandle', 'stdoutLn' gracefully terminates on a broken output pipe
-}
stdoutLn :: MonadIO m => Consumer' String m ()
stdoutLn = go
  where
    go = do
        str <- await
        x   <- liftIO $ try (putStrLn str)
        case x of
           Left (G.IOError { G.ioe_type  = G.ResourceVanished
                           , G.ioe_errno = Just ioe })
                | Errno ioe == ePIPE
                    -> return ()
           Left  e  -> liftIO (throwIO e)
           Right () -> go
{-# INLINABLE stdoutLn #-}

{-| Write 'String's to 'IO.stdout' using 'putStrLn'

    This does not handle a broken output pipe, but has a polymorphic return
    value
-}
stdoutLn' :: MonadIO m => Consumer' String m r
stdoutLn' = for cat (\str -> liftIO (putStrLn str))
{-# INLINABLE [1] stdoutLn' #-}

{-# RULES
    "p >-> stdoutLn'" forall p .
        p >-> stdoutLn' = for p (\str -> liftIO (putStrLn str))
  #-}

-- | Consume all values using a monadic function
mapM_ :: Monad m => (a -> m ()) -> Consumer' a m r
mapM_ f = for cat (\a -> lift (f a))
{-# INLINABLE [1] mapM_ #-}

{-# RULES
    "p >-> mapM_ f" forall p f .
        p >-> mapM_ f = for p (\a -> lift (f a))
  #-}

-- | 'print' values to 'IO.stdout'
print :: (MonadIO m, Show a) => Consumer' a m r
print = for cat (\a -> liftIO (Prelude.print a))
{-# INLINABLE [1] print #-}

{-# RULES
    "p >-> print" forall p .
        p >-> print = for p (\a -> liftIO (Prelude.print a))
  #-}

-- | Write 'String's to a 'IO.Handle' using 'IO.hPutStrLn'
toHandle :: MonadIO m => IO.Handle -> Consumer' String m r
toHandle handle = for cat (\str -> liftIO (IO.hPutStrLn handle str))
{-# INLINABLE [1] toHandle #-}

{-# RULES
    "p >-> toHandle handle" forall p handle .
        p >-> toHandle handle = for p (\str -> liftIO (IO.hPutStrLn handle str))
  #-}

-- | 'discard' all incoming values
drain :: Functor m => Consumer' a m r
drain = for cat discard
{-# INLINABLE [1] drain #-}

{-# RULES
    "p >-> drain" forall p .
        p >-> drain = for p discard
  #-}

{- $pipes
    Use ('>->') to connect 'Producer's, 'Pipe's, and 'Consumer's:

>>> runEffect $ P.stdinLn >-> P.takeWhile (/= "quit") >-> P.stdoutLn
Test<Enter>
Test
ABC<Enter>
ABC
quit<Enter>
>>>

-}

{-| Apply a function to all values flowing downstream

> map id = cat
>
> map (g . f) = map f >-> map g
-}
map :: Functor m => (a -> b) -> Pipe a b m r
map f = for cat (\a -> yield (f a))
{-# INLINABLE [1] map #-}

{-# RULES
    "p >-> map f" forall p f . p >-> map f = for p (\a -> yield (f a))

  ; "map f >-> p" forall p f . map f >-> p = (do
        a <- await
        return (f a) ) >~ p
  #-}

{-| Apply a monadic function to all values flowing downstream

> mapM return = cat
>
> mapM (f >=> g) = mapM f >-> mapM g
-}
mapM :: Monad m => (a -> m b) -> Pipe a b m r
mapM f = for cat $ \a -> do
    b <- lift (f a)
    yield b
{-# INLINABLE [1] mapM #-}

{-# RULES
    "p >-> mapM f" forall p f . p >-> mapM f = for p (\a -> do
        b <- lift (f a)
        yield b )

  ; "mapM f >-> p" forall p f . mapM f >-> p = (do
        a <- await
        b <- lift (f a)
        return b ) >~ p
  #-}

-- | Convert a stream of actions to a stream of values
sequence :: Monad m => Pipe (m a) a m r
sequence = mapM id
{-# INLINABLE sequence #-}

{- | Apply a function to all values flowing downstream, and
     forward each element of the result.
-}
mapFoldable :: (Functor m, Foldable t) => (a -> t b) -> Pipe a b m r
mapFoldable f = for cat (\a -> each (f a))
{-# INLINABLE [1] mapFoldable #-}

{-# RULES
    "p >-> mapFoldable f" forall p f .
        p >-> mapFoldable f = for p (\a -> each (f a))
  #-}

{-| @(filter predicate)@ only forwards values that satisfy the predicate.

> filter (pure True) = cat
>
> filter (liftA2 (&&) p1 p2) = filter p1 >-> filter p2
-}
filter :: Functor m => (a -> Bool) -> Pipe a a m r
filter predicate = for cat $ \a -> when (predicate a) (yield a)
{-# INLINABLE [1] filter #-}

{-# RULES
    "p >-> filter predicate" forall p predicate.
        p >-> filter predicate = for p (\a -> when (predicate a) (yield a))
  #-}

{-| @(filterM predicate)@ only forwards values that satisfy the monadic
    predicate

> filterM (pure (pure True)) = cat
>
> filterM (liftA2 (liftA2 (&&)) p1 p2) = filterM p1 >-> filterM p2
-}
filterM :: Monad m => (a -> m Bool) -> Pipe a a m r
filterM predicate = for cat $ \a -> do
    b <- lift (predicate a)
    when b (yield a)
{-# INLINABLE [1] filterM #-}

{-# RULES
    "p >-> filterM predicate" forall p predicate .
        p >-> filterM predicate = for p (\a -> do
            b <- lift (predicate a)
            when b (yield a) )
  #-}

{-| @(take n)@ only allows @n@ values to pass through

> take 0 = return ()
>
> take (m + n) = take m >> take n

> take <infinity> = cat
>
> take (min m n) = take m >-> take n
-}
take :: Functor m => Int -> Pipe a a m ()
take = go
  where
    go 0 = return () 
    go n = do 
        a <- await
        yield a
        go (n-1)
{-# INLINABLE take #-}

{-| @(takeWhile p)@ allows values to pass downstream so long as they satisfy
    the predicate @p@.

> takeWhile (pure True) = cat
>
> takeWhile (liftA2 (&&) p1 p2) = takeWhile p1 >-> takeWhile p2
-}
takeWhile :: Functor m => (a -> Bool) -> Pipe a a m ()
takeWhile predicate = go
  where
    go = do
        a <- await
        if (predicate a)
            then do
                yield a
                go
            else return ()
{-# INLINABLE takeWhile #-}

{-| @(takeWhile' p)@ is a version of takeWhile that returns the value failing
    the predicate.

> takeWhile' (pure True) = cat
>
> takeWhile' (liftA2 (&&) p1 p2) = takeWhile' p1 >-> takeWhile' p2
-}
takeWhile' :: Functor m => (a -> Bool) -> Pipe a a m a
takeWhile' predicate = go
  where
    go = do
        a <- await
        if (predicate a)
            then do
                yield a
                go
            else return a
{-# INLINABLE takeWhile' #-}

{-| @(drop n)@ discards @n@ values going downstream

> drop 0 = cat
>
> drop (m + n) = drop m >-> drop n
-}
drop :: Functor m => Int -> Pipe a a m r
drop = go
  where
    go 0 = cat
    go n =  do
        await
        go (n-1)
{-# INLINABLE drop #-}

{-| @(dropWhile p)@ discards values going downstream until one violates the
    predicate @p@.

> dropWhile (pure False) = cat
>
> dropWhile (liftA2 (||) p1 p2) = dropWhile p1 >-> dropWhile p2
-}
dropWhile :: Functor m => (a -> Bool) -> Pipe a a m r
dropWhile predicate = go
  where
    go = do
        a <- await
        if (predicate a)
            then go
            else do
                yield a
                cat
{-# INLINABLE dropWhile #-}

-- | Flatten all 'Foldable' elements flowing downstream
concat :: (Functor m, Foldable f) => Pipe (f a) a m r
concat = for cat each
{-# INLINABLE [1] concat #-}

{-# RULES
    "p >-> concat" forall p . p >-> concat = for p each
  #-}

-- | Outputs the indices of all elements that match the given element
elemIndices :: (Functor m, Eq a) => a -> Pipe a Int m r
elemIndices a = findIndices (a ==)
{-# INLINABLE elemIndices #-}

-- | Outputs the indices of all elements that satisfied the predicate
findIndices :: Functor m => (a -> Bool) -> Pipe a Int m r
findIndices predicate = go 0
  where
    go n = do
        a <- await
        when (predicate a) (yield n)
        go $! n + 1
{-# INLINABLE findIndices #-}

{-| Strict left scan

> Control.Foldl.purely scan :: Monad m => Fold a b -> Pipe a b m r
-}
scan :: Functor m => (x -> a -> x) -> x -> (x -> b) -> Pipe a b m r
scan step begin done = go begin
  where
    go x = do
        yield (done x)
        a <- await
        let x' = step x a
        go $! x'
{-# INLINABLE scan #-}

{-| Strict, monadic left scan

> Control.Foldl.impurely scanM :: Monad m => FoldM m a b -> Pipe a b m r
-}
scanM :: Monad m => (x -> a -> m x) -> m x -> (x -> m b) -> Pipe a b m r
scanM step begin done = do
    x <- lift begin
    go x
  where
    go x = do
        b <- lift (done x)
        yield b
        a  <- await
        x' <- lift (step x a)
        go $! x'
{-# INLINABLE scanM #-}

{-| Apply an action to all values flowing downstream

> chain (pure (return ())) = cat
>
> chain (liftA2 (>>) m1 m2) = chain m1 >-> chain m2
-}
chain :: Monad m => (a -> m ()) -> Pipe a a m r
chain f = for cat $ \a -> do
    lift (f a)
    yield a
{-# INLINABLE [1] chain #-}

{-# RULES
    "p >-> chain f" forall p f .
        p >-> chain f = for p (\a -> do
            lift (f a)
            yield a )
  ; "chain f >-> p" forall p f .
        chain f >-> p = (do
            a <- await
            lift (f a)
            return a ) >~ p
  #-}

-- | Parse 'Read'able values, only forwarding the value if the parse succeeds
read :: (Functor m, Read a) => Pipe String a m r
read = for cat $ \str -> case (reads str) of
    [(a, "")] -> yield a
    _         -> return ()
{-# INLINABLE [1] read #-}

{-# RULES
    "p >-> read" forall p .
        p >-> read = for p (\str -> case (reads str) of
            [(a, "")] -> yield a
            _         -> return () )
  #-}

-- | Convert 'Show'able values to 'String's
show :: (Functor m, Show a) => Pipe a String m r
show = map Prelude.show
{-# INLINABLE show #-}

-- | Evaluate all values flowing downstream to WHNF
seq :: Functor m => Pipe a a m r
seq = for cat $ \a -> yield $! a
{-# INLINABLE seq #-}

{-| Create a `Pipe` from a `ListT` transformation

> loop (k1 >=> k2) = loop k1 >-> loop k2
>
> loop return = cat
-}
loop :: Monad m => (a -> ListT m b) -> Pipe a b m r
loop k = for cat (every . k)
{-# INLINABLE loop #-}

{- $folds
    Use these to fold the output of a 'Producer'.  Many of these folds will stop
    drawing elements if they can compute their result early, like 'any':

>>> P.any Prelude.null P.stdinLn
Test<Enter>
ABC<Enter>
<Enter>
True
>>>

-}

{-| Strict fold of the elements of a 'Producer'

> Control.Foldl.purely fold :: Monad m => Fold a b -> Producer a m () -> m b
-}
fold :: Monad m => (x -> a -> x) -> x -> (x -> b) -> Producer a m () -> m b
fold step begin done p0 = go p0 begin
  where
    go p x = case p of
        Request v  _  -> closed v
        Respond a  fu -> go (fu ()) $! step x a
        M          m  -> m >>= \p' -> go p' x
        Pure    _     -> return (done x)
{-# INLINABLE fold #-}

{-| Strict fold of the elements of a 'Producer' that preserves the return value

> Control.Foldl.purely fold' :: Monad m => Fold a b -> Producer a m r -> m (b, r)
-}
fold' :: Monad m => (x -> a -> x) -> x -> (x -> b) -> Producer a m r -> m (b, r)
fold' step begin done p0 = go p0 begin
  where
    go p x = case p of
        Request v  _  -> closed v
        Respond a  fu -> go (fu ()) $! step x a
        M          m  -> m >>= \p' -> go p' x
        Pure    r     -> return (done x, r)
{-# INLINABLE fold' #-}

{-| Strict, monadic fold of the elements of a 'Producer'

> Control.Foldl.impurely foldM :: Monad m => FoldM a b -> Producer a m () -> m b
-}
foldM
    :: Monad m
    => (x -> a -> m x) -> m x -> (x -> m b) -> Producer a m () -> m b
foldM step begin done p0 = do
    x0 <- begin
    go p0 x0
  where
    go p x = case p of
        Request v  _  -> closed v
        Respond a  fu -> do
            x' <- step x a
            go (fu ()) $! x'
        M          m  -> m >>= \p' -> go p' x
        Pure    _     -> done x
{-# INLINABLE foldM #-}

{-| Strict, monadic fold of the elements of a 'Producer'

> Control.Foldl.impurely foldM' :: Monad m => FoldM a b -> Producer a m r -> m (b, r)
-}
foldM'
    :: Monad m
    => (x -> a -> m x) -> m x -> (x -> m b) -> Producer a m r -> m (b, r)
foldM' step begin done p0 = do
    x0 <- begin
    go p0 x0
  where
    go p x = case p of
        Request v  _  -> closed v
        Respond a  fu -> do
            x' <- step x a
            go (fu ()) $! x'
        M          m  -> m >>= \p' -> go p' x
        Pure    r     -> do
            b <- done x
            return (b, r)
{-# INLINABLE foldM' #-}

{-| @(all predicate p)@ determines whether all the elements of @p@ satisfy the
    predicate.
-}
all :: Monad m => (a -> Bool) -> Producer a m () -> m Bool
all predicate p = null $ p >-> filter (\a -> not (predicate a))
{-# INLINABLE all #-}

{-| @(any predicate p)@ determines whether any element of @p@ satisfies the
    predicate.
-}
any :: Monad m => (a -> Bool) -> Producer a m () -> m Bool
any predicate p = liftM not $ null (p >-> filter predicate)
{-# INLINABLE any #-}

-- | Determines whether all elements are 'True'
and :: Monad m => Producer Bool m () -> m Bool
and = all id
{-# INLINABLE and #-}

-- | Determines whether any element is 'True'
or :: Monad m => Producer Bool m () -> m Bool
or = any id
{-# INLINABLE or #-}

{-| @(elem a p)@ returns 'True' if @p@ has an element equal to @a@, 'False'
    otherwise
-}
elem :: (Monad m, Eq a) => a -> Producer a m () -> m Bool
elem a = any (a ==)
{-# INLINABLE elem #-}

{-| @(notElem a)@ returns 'False' if @p@ has an element equal to @a@, 'True'
    otherwise
-}
notElem :: (Monad m, Eq a) => a -> Producer a m () -> m Bool
notElem a = all (a /=)
{-# INLINABLE notElem #-}

-- | Find the first element of a 'Producer' that satisfies the predicate
find :: Monad m => (a -> Bool) -> Producer a m () -> m (Maybe a)
find predicate p = head (p >-> filter predicate)
{-# INLINABLE find #-}

{-| Find the index of the first element of a 'Producer' that satisfies the
    predicate
-}
findIndex :: Monad m => (a -> Bool) -> Producer a m () -> m (Maybe Int)
findIndex predicate p = head (p >-> findIndices predicate)
{-# INLINABLE findIndex #-}

-- | Retrieve the first element from a 'Producer'
head :: Monad m => Producer a m () -> m (Maybe a)
head p = do
    x <- next p
    return $ case x of
        Left   _     -> Nothing
        Right (a, _) -> Just a
{-# INLINABLE head #-}

-- | Index into a 'Producer'
index :: Monad m => Int -> Producer a m () -> m (Maybe a)
index n p = head (p >-> drop n)
{-# INLINABLE index #-}

-- | Retrieve the last element from a 'Producer'
last :: Monad m => Producer a m () -> m (Maybe a)
last p0 = do
    x <- next p0
    case x of
        Left   _      -> return Nothing
        Right (a, p') -> go a p'
  where
    go a p = do
        x <- next p
        case x of
            Left   _       -> return (Just a)
            Right (a', p') -> go a' p'
{-# INLINABLE last #-}

-- | Count the number of elements in a 'Producer'
length :: Monad m => Producer a m () -> m Int
length = fold (\n _ -> n + 1) 0 id
{-# INLINABLE length #-}

-- | Find the maximum element of a 'Producer'
maximum :: (Monad m, Ord a) => Producer a m () -> m (Maybe a)
maximum = fold step Nothing id
  where
    step x a = Just $ case x of
        Nothing -> a
        Just a' -> max a a'
{-# INLINABLE maximum #-}

-- | Find the minimum element of a 'Producer'
minimum :: (Monad m, Ord a) => Producer a m () -> m (Maybe a)
minimum = fold step Nothing id
  where
    step x a = Just $ case x of
        Nothing -> a
        Just a' -> min a a'
{-# INLINABLE minimum #-}

-- | Determine if a 'Producer' is empty
null :: Monad m => Producer a m () -> m Bool
null p = do
    x <- next p
    return $ case x of
        Left  _ -> True
        Right _ -> False
{-# INLINABLE null #-}

-- | Compute the sum of the elements of a 'Producer'
sum :: (Monad m, Num a) => Producer a m () -> m a
sum = fold (+) 0 id
{-# INLINABLE sum #-}

-- | Compute the product of the elements of a 'Producer'
product :: (Monad m, Num a) => Producer a m () -> m a
product = fold (*) 1 id
{-# INLINABLE product #-}

-- | Convert a pure 'Producer' into a list
toList :: Producer a Identity () -> [a]
toList prod0 = build (go prod0)
  where
    go prod cons nil =
      case prod of
        Request v _  -> closed v
        Respond a fu -> cons a (go (fu ()) cons nil)
        M         m  -> go (runIdentity m) cons nil
        Pure    _    -> nil
{-# INLINE toList #-}

{-| Convert an effectful 'Producer' into a list

    Note: 'toListM' is not an idiomatic use of @pipes@, but I provide it for
    simple testing purposes.  Idiomatic @pipes@ style consumes the elements
    immediately as they are generated instead of loading all elements into
    memory.
-}
toListM :: Monad m => Producer a m () -> m [a]
toListM = fold step begin done
  where
    step x a = x . (a:)
    begin = id
    done x = x []
{-# INLINABLE toListM #-}

{-| Convert an effectful 'Producer' into a list alongside the return value

    Note: 'toListM'' is not an idiomatic use of @pipes@, but I provide it for
    simple testing purposes.  Idiomatic @pipes@ style consumes the elements
    immediately as they are generated instead of loading all elements into
    memory.
-}
toListM' :: Monad m => Producer a m r -> m ([a], r)
toListM' = fold' step begin done
  where
    step x a = x . (a:)
    begin = id
    done x = x []
{-# INLINABLE toListM' #-}

-- | Zip two 'Producer's
zip :: Monad m
    => (Producer   a     m r)
    -> (Producer      b  m r)
    -> (Producer' (a, b) m r)
zip = zipWith (,)
{-# INLINABLE zip #-}

-- | Zip two 'Producer's using the provided combining function
zipWith :: Monad m
    => (a -> b -> c)
    -> (Producer  a m r)
    -> (Producer  b m r)
    -> (Producer' c m r)
zipWith f = go
  where
    go p1 p2 = do
        e1 <- lift $ next p1
        case e1 of
            Left r         -> return r
            Right (a, p1') -> do
                e2 <- lift $ next p2
                case e2 of
                    Left r         -> return r
                    Right (b, p2') -> do
                        yield (f a b)
                        go p1' p2'
{-# INLINABLE zipWith #-}

{-| Transform a 'Consumer' to a 'Pipe' that reforwards all values further
    downstream
-}
tee :: Monad m => Consumer a m r -> Pipe a a m r
tee p = evalStateP Nothing $ do
    r <- up >\\ (hoist lift p //> dn)
    ma <- lift get
    case ma of
        Nothing -> return ()
        Just a  -> yield a
    return r
  where
    up () = do
        ma <- lift get
        case ma of
            Nothing -> return ()
            Just a  -> yield a
        a <- await
        lift $ put (Just a)
        return a
    dn v = closed v
{-# INLINABLE tee #-}

{-| Transform a unidirectional 'Pipe' to a bidirectional 'Proxy'

> generalize (f >-> g) = generalize f >+> generalize g
>
> generalize cat = pull
-}
generalize :: Monad m => Pipe a b m r -> x -> Proxy x a x b m r
generalize p x0 = evalStateP x0 $ up >\\ hoist lift p //> dn
  where
    up () = do
        x <- lift get
        request x
    dn a = do
        x <- respond a
        lift $ put x
{-# INLINABLE generalize #-}

{-| The natural unfold into a 'Producer' with a step function and a seed 

> unfoldr next = id
-}
unfoldr :: Monad m 
        => (s -> m (Either r (a, s))) -> s -> Producer a m r
unfoldr step = go where
  go s0 = do
    e <- lift (step s0)
    case e of
      Left r -> return r
      Right (a,s) -> do 
        yield a
        go s
{-# INLINABLE unfoldr #-}
