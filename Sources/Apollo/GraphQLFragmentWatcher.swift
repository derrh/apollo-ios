import Foundation
#if !COCOAPODS
  import ApolloAPI
#endif

/// A `GraphQLFragmentWatcher` is responsible for watching the store, and calling the result handler with a new result
/// whenever any of the data the
/// previous result depends on changes.
///
/// NOTE: The store retains the watcher while subscribed. You must call `cancel()` on your fragment watcher when you no
/// longer need results. Failure
/// to
/// call `cancel()` before releasing your reference to the returned watcher will result in a memory leak.
public final class GraphQLFragmentWatcher<FragmentType: Fragment & RootSelectionSet>: Cancellable,
  ApolloStoreSubscriber {
  weak var client: ApolloClientProtocol?
  public let cacheKey: String
  let resultHandler: (Result<FragmentType?, Error>) -> Void

  private let callbackQueue: DispatchQueue

  @Atomic private var dependentKeys: Set<CacheKey>? = nil

  /// Designated initializer
  ///
  /// - Parameters:
  ///   - client: The client protocol to pass in.
  ///   - fragment: The fragment to watch.
  ///   - callbackQueue: The queue for the result handler. Defaults to the main queue.
  ///   - resultHandler: The result handler to call with changes.
  public init(
    client: ApolloClientProtocol,
    cacheKey: CacheKey,
    callbackQueue: DispatchQueue = .main,
    resultHandler: @escaping (Result<FragmentType?, Error>) -> Void
  ) {
    self.client = client
    self.cacheKey = cacheKey
    self.resultHandler = resultHandler
    self.callbackQueue = callbackQueue

    client.store.subscribe(self)
    readAndDispatchFromStore()
  }

  private func readAndDispatchFromStore() {
    // load the initial value
    client?.store.withinReadTransaction { tx in
      do {
        let readResult = try tx.readObject(
          ofType: FragmentType.self,
          withKey: self.cacheKey,
          accumulator: zip(
            GraphQLSelectionSetMapper<FragmentType>(),
            GraphQLDependencyTracker()
          )
        )
        self.$dependentKeys.mutate { $0 = readResult.1 }
        self.callbackQueue.async {
          self.resultHandler(.success(readResult.0))
        }
      } catch {
        // TODO: handle errors
        self.callbackQueue.async {
          self.resultHandler(.failure(error))
        }
      }
    }
  }

  /// Cancel any in progress fetching operations and unsubscribe from the store.
  public func cancel() {
    client?.store.unsubscribe(self)
  }

  func store(
    _: ApolloStore,
    didChangeKeys changedKeys: Set<CacheKey>,
    contextIdentifier _: UUID?
  ) {
    guard
      let dependentKeys = dependentKeys,
      !dependentKeys.isDisjoint(with: changedKeys)
    else {
      // This fragment has nil dependent keys, so nothing that changed will affect it.
      return
    }

    readAndDispatchFromStore()
  }
}
