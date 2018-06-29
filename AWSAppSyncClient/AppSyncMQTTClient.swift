//
//  AppSyncMQTTClient.swift
//  AWSAppSync
//

import Foundation
import Reachability


class AppSyncMQTTClient: MQTTClientDelegate {
    
    var mqttClient = MQTTClient<AnyObject, AnyObject>()
    var mqttClients = Set<MQTTClient<AnyObject, AnyObject>>()
    var mqttClientsWithTopics = [MQTTClient<AnyObject, AnyObject>: Set<String>]()
    var reachability: Reachability?
    var hostURL: String?
    var clientId: String?
    var topicSubscribersDictionary = [String: [MQTTSubscritionWatcher]]()
    var initialConnection = true
    var shouldSubscribe = true

    var allowCellularAccess = true
    var scheduledSubscription: DispatchSourceTimer?
    var subscriptionQueue = DispatchQueue.global(qos: .userInitiated)
    
    func receivedMessageData(_ data: Data!, onTopic topic: String!) {
        
        subscriptionQueue.async {[weak self] in
            guard let strongSelf = self else {
                return
            }
            let topics = strongSelf.topicSubscribersDictionary[topic]
            for subscribedTopic in topics! {
                subscribedTopic.messageCallbackDelegate(data: data)
            }
        }

    }
    
    func connectionStatusChanged(_ status: MQTTStatus, client mqttClient: MQTTClient<AnyObject, AnyObject>) {
        
        subscriptionQueue.async {[weak self] in
            guard let strongSelf = self else {
                return
            }
            //prepare to refactor this part
            switch status {
                
            case .unknown, .connecting, .connectionRefused, .disconnected, .protocolError:
                guard strongSelf.mqttClientsWithTopics[mqttClient] != nil else {return} //added to make sure no issue, follow master commit
                
                for topic in strongSelf.mqttClientsWithTopics[mqttClient]! {
                    let subscribers = strongSelf.topicSubscribersDictionary[topic]
                    for subscriber in subscribers! {
                        subscriber.otherConnectionCallbackDelegate(status: status)
                    }
                }
                
            case .connected:
                guard strongSelf.mqttClientsWithTopics[mqttClient] != nil else {return} //added to make sure no issue, follow master commit
                
                for topic in strongSelf.mqttClientsWithTopics[mqttClient]! {
                    mqttClient.subscribe(toTopic: topic, qos: 1, extendedCallback: nil)
                    let subscribers = strongSelf.topicSubscribersDictionary[topic]
                    for subscriber in subscribers! {
                        subscriber.otherConnectionCallbackDelegate(status: status)
                    }
                }
                
            case .connectionError:
                guard strongSelf.mqttClientsWithTopics[mqttClient] != nil else {return} //added by master commit
                
                for topic in strongSelf.mqttClientsWithTopics[mqttClient]! {
                    let subscribers = strongSelf.topicSubscribersDictionary[topic]
                    for subscriber in subscribers! {
                        let error = AWSAppSyncSubscriptionError(additionalInfo: "Subscription Terminated.", errorDetails:  [
                            "recoverySuggestion" : "Restart subscription request.",
                            "failureReason" : "Disconnected from service."])
                        
                        subscriber.disconnectCallbackDelegate(error: error)
                    }
                }
            }

        }
    }
    
    func addWatcher(watcher: MQTTSubscritionWatcher, topics: [String], identifier: Int) {
        subscriptionQueue.async {[weak self] in
            guard let strongSelf = self else {
                return
            }
            
            for topic in topics {
                if var topicsDict = strongSelf.topicSubscribersDictionary[topic] {
                    topicsDict.append(watcher)
                    strongSelf.topicSubscribersDictionary[topic] = topicsDict
                } else {
                    strongSelf.topicSubscribersDictionary[topic] = [watcher]
                }
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
        mqttClients.removeAll()
        mqttClientsWithTopics.removeAll()
        
        for subscription in subscriptionInfo {
            startNewSubscription(subscriptionInfo: subscription)
        }
    }
    

    func startNewSubscription(subscriptionInfo: AWSSubscriptionInfo) {
        let interestedTopics = subscriptionInfo.topics.filter({ topicSubscribersDictionary[$0] != nil })
        
        guard !interestedTopics.isEmpty else {
            return
        }
        
        let mqttClient = MQTTClient<AnyObject, AnyObject>()
        mqttClient.clientDelegate = self
        
        mqttClients.insert(mqttClient)
        mqttClientsWithTopics[mqttClient] = Set(interestedTopics)

        mqttClient.connect(withClientId: subscriptionInfo.clientId, toHost: subscriptionInfo.url, statusCallback: nil)
    }

    public func stopSubscription(subscription: MQTTSubscritionWatcher) {
        
        self.subscriptionQueue.async {[weak self] in
            guard let strongSelf = self else {
                return
            }
            strongSelf.topicSubscribersDictionary = strongSelf.updatedDictionary(strongSelf.topicSubscribersDictionary, usingCancelling: subscription)
            
            strongSelf.topicSubscribersDictionary.filter({ $0.value.isEmpty })
                .map({ $0.key })
                .forEach(strongSelf.unsubscribeTopic)
            
            for (client, _) in strongSelf.mqttClientsWithTopics.filter({ $0.value.isEmpty }) {
//                DispatchQueue.global(qos: .userInitiated).async { //might not be necessary since already in a subscription queue, will test
                    client.disconnect()
//                }
                
                strongSelf.mqttClientsWithTopics[client] = nil
                strongSelf.mqttClients.remove(client)
            }
        }

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

        for (client, _) in mqttClientsWithTopics.filter({ $0.value.contains(topic) }) {

            client.unsubscribeTopic(topic)
            mqttClientsWithTopics[client]?.remove(topic)
        }
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
