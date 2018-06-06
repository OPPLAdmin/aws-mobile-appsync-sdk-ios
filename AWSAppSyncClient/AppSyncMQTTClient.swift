//
//  AppSyncMQTTClient.swift
//  AWSAppSync
//

import Foundation
import Reachability


class AppSyncMQTTClient: MQTTClientDelegate {
    
    var mqttClients = [MQTTClient<AnyObject, AnyObject>]()
    var mqttClientsWithTopics = [MQTTClient<AnyObject, AnyObject>: [String]]()
    var topicSubscribersDictionary = [String: [MQTTSubscritionWatcher]]()
    var topicQueue = NSMutableSet()
    var allowCellularAccess = true
    var scheduledSubscription: DispatchSourceTimer?
    var subscriptionQueue = DispatchQueue.global(qos: .userInitiated)
    
    func receivedMessageData(_ data: Data!, onTopic topic: String!) {
        let topics = topicSubscribersDictionary[topic]
        for subscribedTopic in topics! {
            subscribedTopic.messageCallbackDelegate(data: data)
        }
    }
    
    func connectionStatusChanged(_ status: MQTTStatus, client mqttClient: MQTTClient<AnyObject, AnyObject>) {
        
       //prepare to refactor this part
        switch status {
            
        case .unknown, .connecting, .connectionRefused, .disconnected, .protocolError:
            for topic in mqttClientsWithTopics[mqttClient]! {
                let subscribers = topicSubscribersDictionary[topic]
                for subscriber in subscribers! {
                    subscriber.otherConnectionCallbackDelegate(status: status)
                }
            }
        
        case .connected:
            for topic in mqttClientsWithTopics[mqttClient]! {
                mqttClient.subscribe(toTopic: topic, qos: 1, extendedCallback: nil)
                let subscribers = topicSubscribersDictionary[topic]
                for subscriber in subscribers! {
                    subscriber.otherConnectionCallbackDelegate(status: status)
                }
            }
        case .connectionError:
            for topic in mqttClientsWithTopics[mqttClient]! {
                let subscribers = topicSubscribersDictionary[topic]
                for subscriber in subscribers! {
                    let error = AWSAppSyncSubscriptionError(additionalInfo: "Subscription Terminated.", errorDetails:  [
                        "recoverySuggestion" : "Restart subscription request.",
                        "failureReason" : "Disconnected from service."])
                    
                    subscriber.disconnectCallbackDelegate(error: error)
                }
            }
        }

        
        
//        if status.rawValue == 2 {
//            for topic in mqttClientsWithTopics[mqttClient]! {
//                mqttClient.subscribe(toTopic: topic, qos: 1, extendedCallback: nil)
//            }
//            self.topicQueue = NSMutableSet()
//        } else if status.rawValue >= 3  {
//            for topic in mqttClientsWithTopics[mqttClient]! {
//                let subscribers = topicSubscribersDictionary[topic]
//                for subscriber in subscribers! {
//                    let error = AWSAppSyncSubscriptionError(additionalInfo: "Subscription Terminated.", errorDetails:  [
//                        "recoverySuggestion" : "Restart subscription request.",
//                        "failureReason" : "Disconnected from service."])
//
//                    subscriber.disconnectCallbackDelegate(error: error)
//                }
//            }
//        }
    }
    
    func addWatcher(watcher: MQTTSubscritionWatcher, topics: [String], identifier: Int) {
        for topic in topics {
            if var topicsDict = self.topicSubscribersDictionary[topic] {
                topicsDict.append(watcher)
                self.topicSubscribersDictionary[topic] = topicsDict
            } else {
                self.topicSubscribersDictionary[topic] = [watcher]
            }
        }
    }
    
    func startSubscriptions(subscriptionInfo: [AWSSubscriptionInfo]) {
        func createTimer(_ interval: Int, queue: DispatchQueue, block: @escaping () -> Void) -> DispatchSourceTimer {
            let timer = DispatchSource.makeTimerSource(flags: DispatchSource.TimerFlags(rawValue: 0), queue: queue)
            #if swift(>=4)
            timer.schedule(deadline: .now() + .seconds(interval))
            #else
            timer.scheduleOneshot(deadline: .now() + .seconds(interval))
            #endif
            timer.setEventHandler(handler: block)
            timer.resume()
            return timer
        }
        scheduledSubscription = createTimer(1, queue: subscriptionQueue, block: {[weak self] in
            self?.resetAndStartSubscriptions(subscriptionInfo: subscriptionInfo)
        })
    }
    
    private func resetAndStartSubscriptions(subscriptionInfo: [AWSSubscriptionInfo]) {
        for client in mqttClients {
            client.clientDelegate = nil
            client.disconnect()
        }
    }
    
    private func startNewSubscription(subscriptionInfo: AWSSubscriptionInfo) {
        var topicQueue = [String]()
        let mqttClient = MQTTClient<AnyObject, AnyObject>()
        mqttClient.clientDelegate = self
        for topic in subscriptionInfo.topics {
            if topicSubscribersDictionary[topic] != nil {
                // if the client wants subscriptions and is allowed we add it to list of subscribe
                topicQueue.append(topic)
            }
        }
        mqttClients.append(mqttClient)
        mqttClientsWithTopics[mqttClient] = topicQueue
        mqttClient.connect(withClientId: subscriptionInfo.clientId, toHost: subscriptionInfo.url, statusCallback: nil)
    }

    public func stopSubscription(subscription: MQTTSubscritionWatcher) {
        
        topicSubscribersDictionary = updatedDictionary(topicSubscribersDictionary, usingCancelling: subscription)
        
        topicSubscribersDictionary.filter({ $0.value.isEmpty })
                                  .map({ $0.key })
                                  .forEach(unsubscribeTopic)
    }
    
    
    /// Returnes updated dictionary
    /// it removes subscriber from the array
    ///
    /// - Parameters:
    ///   - dictionary: [String: [MQTTSubscritionWatcher]]
    ///   - subscription: MQTTSubscritionWatcher
    /// - Returns: [String: [MQTTSubscritionWatcher]]
    private func updatedDictionary(_ dictionary: [String: [MQTTSubscritionWatcher]] ,
                                   usingCancelling subscription: MQTTSubscritionWatcher) -> [String: [MQTTSubscritionWatcher]] {
        
        return topicSubscribersDictionary.reduce(into: [:]) { (result, element) in
            result[element.key] = removedSubscriber(array: element.value, of: subscription.getIdentifier())
        }
    }
    
    
    
    /// Unsubscribe topic
    ///
    /// - Parameter topic: String
    private func unsubscribeTopic(topic: String) {
        mqttClientsWithTopics.filter({ $0.value.contains(topic) })
                             .forEach({ $0.key.unsubscribeTopic(topic) })
    }
    
    /// Removes subscriber from the array using id
    ///
    /// - Parameters:
    ///   - array: [MQTTSubscritionWatcher]
    ///   - id: Int
    /// - Returns: updated array [MQTTSubscritionWatcher]
    private func removedSubscriber(array: [MQTTSubscritionWatcher], of id: Int) -> [MQTTSubscritionWatcher] {
        return array.filter({$0.getIdentifier() != id })
    }
}
