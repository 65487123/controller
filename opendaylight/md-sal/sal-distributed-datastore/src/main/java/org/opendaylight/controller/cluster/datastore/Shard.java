/*
 * Copyright (c) 2014 Cisco Systems, Inc. and others.  All rights reserved.
 *
 * This program and the accompanying materials are made available under the
 * terms of the Eclipse Public License v1.0 which accompanies this distribution,
 * and is available at http://www.eclipse.org/legal/epl-v10.html
 */

package org.opendaylight.controller.cluster.datastore;

import akka.actor.ActorRef;
import akka.actor.ActorSelection;
import akka.actor.Props;
import akka.event.Logging;
import akka.event.LoggingAdapter;
import akka.japi.Creator;
import akka.persistence.Persistent;
import akka.persistence.RecoveryCompleted;
import akka.persistence.UntypedProcessor;
import com.google.common.util.concurrent.ListenableFuture;
import com.google.common.util.concurrent.ListeningExecutorService;
import com.google.common.util.concurrent.MoreExecutors;
import org.opendaylight.controller.cluster.datastore.jmx.mbeans.shard.ShardMBeanFactory;
import org.opendaylight.controller.cluster.datastore.jmx.mbeans.shard.ShardStats;
import org.opendaylight.controller.cluster.datastore.messages.CommitTransactionReply;
import org.opendaylight.controller.cluster.datastore.messages.CreateTransaction;
import org.opendaylight.controller.cluster.datastore.messages.CreateTransactionChain;
import org.opendaylight.controller.cluster.datastore.messages.CreateTransactionChainReply;
import org.opendaylight.controller.cluster.datastore.messages.CreateTransactionReply;
import org.opendaylight.controller.cluster.datastore.messages.ForwardedCommitTransaction;
import org.opendaylight.controller.cluster.datastore.messages.NonPersistent;
import org.opendaylight.controller.cluster.datastore.messages.RegisterChangeListener;
import org.opendaylight.controller.cluster.datastore.messages.RegisterChangeListenerReply;
import org.opendaylight.controller.cluster.datastore.messages.UpdateSchemaContext;
import org.opendaylight.controller.cluster.datastore.modification.Modification;
import org.opendaylight.controller.cluster.datastore.modification.MutableCompositeModification;
import org.opendaylight.controller.md.sal.common.api.data.AsyncDataChangeListener;
import org.opendaylight.controller.md.sal.dom.store.impl.InMemoryDOMDataStore;
import org.opendaylight.controller.sal.core.spi.data.DOMStoreReadWriteTransaction;
import org.opendaylight.controller.sal.core.spi.data.DOMStoreThreePhaseCommitCohort;
import org.opendaylight.controller.sal.core.spi.data.DOMStoreTransactionChain;
import org.opendaylight.yangtools.yang.data.api.YangInstanceIdentifier;
import org.opendaylight.yangtools.yang.data.api.schema.NormalizedNode;
import org.opendaylight.yangtools.yang.model.api.SchemaContext;

import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.Executors;

/**
 * A Shard represents a portion of the logical data tree <br/>
 * <p>
 * Our Shard uses InMemoryDataStore as it's internal representation and delegates all requests it
 * </p>
 */
public class Shard extends UntypedProcessor {

    public static final String DEFAULT_NAME = "default";

    private final ListeningExecutorService storeExecutor =
        MoreExecutors.listeningDecorator(Executors.newFixedThreadPool(2));

    private final InMemoryDOMDataStore store;

    private final Map<Object, DOMStoreThreePhaseCommitCohort>
        modificationToCohort = new HashMap<>();

    private final LoggingAdapter LOG =
        Logging.getLogger(getContext().system(), this);

    // By default persistent will be true and can be turned off using the system
    // property persistent
    private final boolean persistent;

    private SchemaContext schemaContext;

    private final ShardStats shardMBean;

    private Shard(String name) {

        String setting = System.getProperty("shard.persistent");

        this.persistent = !"false".equals(setting);

        LOG.info("Creating shard : {} persistent : {}", name, persistent);

        store = new InMemoryDOMDataStore(name, storeExecutor);

        shardMBean = ShardMBeanFactory.getShardStatsMBean(name);

    }

    public static Props props(final String name) {
        return Props.create(new Creator<Shard>() {

            @Override
            public Shard create() throws Exception {
                return new Shard(name);
            }

        });
    }


    @Override
    public void onReceive(Object message) throws Exception {
        LOG.debug("Received message " + message.getClass().toString());

        if(!recoveryFinished()){
            // FIXME : Properly handle recovery
            return;
        }

        if (message.getClass().equals(CreateTransactionChain.SERIALIZABLE_CLASS)) {
            createTransactionChain();
        } else if (message.getClass().equals(RegisterChangeListener.SERIALIZABLE_CLASS)) {
            registerChangeListener(RegisterChangeListener.fromSerializable(getContext().system(), message));
        } else if (message instanceof UpdateSchemaContext) {
            updateSchemaContext((UpdateSchemaContext) message);
        } else if (message instanceof ForwardedCommitTransaction) {
            handleForwardedCommit((ForwardedCommitTransaction) message);
        } else if (message instanceof Persistent) {
            commit(((Persistent)message).payload());
        } else if (message.getClass().equals(CreateTransaction.SERIALIZABLE_CLASS)) {
            createTransaction(CreateTransaction.fromSerializable(message));
        } else if(message instanceof NonPersistent){
            commit(((NonPersistent)message).payload());
        }else if (message instanceof RecoveryCompleted) {
            //FIXME: PROPERLY HANDLE RECOVERY COMPLETED

        }else {
          throw new Exception("Not recognized message found message=" + message);
        }
    }

    private void createTransaction(CreateTransaction createTransaction) {
        DOMStoreReadWriteTransaction transaction =
            store.newReadWriteTransaction();
        ActorRef transactionActor = getContext().actorOf(
            ShardTransaction.props(transaction, getSelf(), schemaContext), "shard-" + createTransaction.getTransactionId());
        getSender()
            .tell(new CreateTransactionReply(transactionActor.path().toString(), createTransaction.getTransactionId()).toSerializable(),
                getSelf());
    }

    private void commit(Object serialized) {
        Modification modification = MutableCompositeModification.fromSerializable(serialized, schemaContext);
        DOMStoreThreePhaseCommitCohort cohort =
            modificationToCohort.remove(serialized);
        if (cohort == null) {
            LOG.error(
                "Could not find cohort for modification : " + modification);
            return;
        }
        final ListenableFuture<Void> future = cohort.commit();
        shardMBean.incrementCommittedTransactionCount();
        final ActorRef sender = getSender();
        final ActorRef self = getSelf();
        future.addListener(new Runnable() {
            @Override
            public void run() {
                try {
                    future.get();
                    sender.tell(new CommitTransactionReply().toSerializable(), self);
                } catch (InterruptedException | ExecutionException e) {
                    // FIXME : Handle this properly
                    LOG.error(e, "An exception happened when committing");
                }
            }
        }, getContext().dispatcher());
    }

    private void handleForwardedCommit(ForwardedCommitTransaction message) {
        Object serializedModification = message.getModification().toSerializable();

        modificationToCohort
            .put(serializedModification , message.getCohort());
        if(persistent) {
            getSelf().forward(Persistent.create(serializedModification),
                getContext());
        } else {
            getSelf().forward(NonPersistent.create(serializedModification),
                getContext());
        }
    }

    private void updateSchemaContext(UpdateSchemaContext message) {
        this.schemaContext = message.getSchemaContext();
        store.onGlobalContextUpdated(message.getSchemaContext());
    }

    private void registerChangeListener(
        RegisterChangeListener registerChangeListener) {

        LOG.debug("registerDataChangeListener for " + registerChangeListener.getPath());


        ActorSelection dataChangeListenerPath = getContext()
            .system().actorSelection(registerChangeListener.getDataChangeListenerPath());

        AsyncDataChangeListener<YangInstanceIdentifier, NormalizedNode<?, ?>>
            listener = new DataChangeListenerProxy(schemaContext,dataChangeListenerPath);

        org.opendaylight.yangtools.concepts.ListenerRegistration<AsyncDataChangeListener<YangInstanceIdentifier, NormalizedNode<?, ?>>>
            registration =
            store.registerChangeListener(registerChangeListener.getPath(),
                listener, registerChangeListener.getScope());
        ActorRef listenerRegistration =
            getContext().actorOf(
                DataChangeListenerRegistration.props(registration));

        LOG.debug("registerDataChangeListener sending reply, listenerRegistrationPath = " + listenerRegistration.path().toString());

        getSender()
            .tell(new RegisterChangeListenerReply(listenerRegistration.path()).toSerializable(),
                getSelf());
    }

    private void createTransactionChain() {
        DOMStoreTransactionChain chain = store.createTransactionChain();
        ActorRef transactionChain =
            getContext().actorOf(ShardTransactionChain.props(chain, schemaContext));
        getSender()
            .tell(new CreateTransactionChainReply(transactionChain.path()).toSerializable(),
                getSelf());
    }
}
